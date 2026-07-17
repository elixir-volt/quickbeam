defmodule QuickBEAM.VM.Runtime.Exception do
  @moduledoc """
  Converts VM-generated failures into catchable owner-local JavaScript errors.

  JavaScript values remain heap references while code can catch them. Conversion
  to `QuickBEAM.JSError` happens only after a value escapes the evaluation.
  """

  alias QuickBEAM.VM.Builtin.Runtime, as: BuiltinRuntime
  alias QuickBEAM.VM.Bytecode.Atom, as: AtomTable
  alias QuickBEAM.VM.Program.Function
  alias QuickBEAM.VM.Runtime.Async
  alias QuickBEAM.VM.Runtime.Boundary
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.Frame.Native
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Object
  alias QuickBEAM.VM.Runtime.Promise
  alias QuickBEAM.VM.Runtime.Property
  alias QuickBEAM.VM.Runtime.Reference
  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Value

  alias QuickBEAM.VM.Runtime.Thrown

  @type action ::
          {:run, Frame.t(), State.t()}
          | {:resume_then_getter, Boundary.ThenGetter.t(), State.t()}
          | {:complete, term(), term(), State.t(), boolean()}
          | {:async, Async.result()}
          | {:idle, State.t()}
          | {:error, QuickBEAM.JSError.t(), State.t()}

  @doc "Raises a value at the current frame and plans catch or unwind execution."
  @spec throw_at(term(), Frame.t() | Native.t(), State.t()) :: action()
  def throw_at(reason, %Native{caller: caller}, execution) do
    {reason, trace, execution} = throw_state(reason, execution)
    do_throw(reason, caller, execution, trace, true)
  end

  def throw_at(reason, %Frame{} = frame, execution) do
    {reason, trace, execution} = throw_state(reason, execution)
    do_throw(reason, frame, execution, trace, false)
  end

  @doc "Raises a value from an invocation boundary and plans its continuation."
  @spec throw_from(term(), term(), State.t()) :: action()
  def throw_from(reason, boundary, execution) do
    {reason, trace, execution} = throw_state(reason, execution)
    throw_from_boundary(reason, boundary, execution, trace)
  end

  @doc "Materializes a generated VM exception as a JavaScript heap value."
  @spec materialize(term(), State.t()) :: {term(), State.t()}
  def materialize(reason, execution) do
    case QuickBEAM.JSError.vm_exception_value(reason) do
      %{} = value when not is_struct(value) ->
        name = to_string(value[:name] || value["name"] || "Error")
        message = to_string(value[:message] || value["message"] || "")
        BuiltinRuntime.new_error(execution, name, message)

      value ->
        {value, execution}
    end
  end

  @doc "Converts an uncaught JavaScript value into the stable public error struct."
  @spec to_js_error(term(), State.t(), [QuickBEAM.JSError.frame()]) :: QuickBEAM.JSError.t()
  def to_js_error(%Thrown{value: value, frames: async_frames}, execution, frames),
    do: to_js_error(value, execution, async_frames ++ frames)

  def to_js_error(%Reference{} = reference, execution, frames) do
    case details(reference, execution) do
      {:ok, value} -> QuickBEAM.JSError.from_vm(value, frames)
      :error -> QuickBEAM.JSError.from_vm(reference, frames)
    end
  end

  def to_js_error(reason, _execution, frames), do: QuickBEAM.JSError.from_vm(reason, frames)

  @doc "Returns the public name and message of an owner-local JavaScript error object."
  @spec details(Reference.t(), State.t()) :: {:ok, map()} | :error
  def details(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{internal: {:error, default_name}}} ->
        name =
          case Property.get(reference, "name", execution) do
            {:ok, value} when value not in [:undefined, nil] -> to_string_value(value)
            _missing -> default_name
          end

        message =
          case Property.get(reference, "message", execution) do
            {:ok, :undefined} -> ""
            {:ok, value} -> to_string_value(value)
            {:error, _reason} -> ""
          end

        {:ok, %{"name" => name, "message" => message}}

      _not_error ->
        :error
    end
  end

  defp throw_state(%Thrown{value: value, frames: frames}, execution) do
    {value, execution} = materialize(value, execution)
    {value, Enum.reverse(frames), execution}
  end

  defp throw_state(reason, execution) do
    {value, execution} = materialize(reason, execution)
    {value, [], execution}
  end

  defp throw_from_boundary(reason, %Boundary.ObjectAssign{} = boundary, execution, trace),
    do: do_throw(reason, boundary.caller, execution, trace, true)

  defp throw_from_boundary(reason, %Boundary.ThenGetter{} = boundary, execution, trace) do
    thrown = thrown(reason, trace)
    execution = Promise.settle_assimilated(execution, boundary.promise, {:error, thrown})
    {:resume_then_getter, boundary, execution}
  end

  defp throw_from_boundary(reason, %Boundary.Accessor{} = boundary, execution, trace),
    do: do_throw(reason, boundary.caller, execution, trace, true)

  defp throw_from_boundary(reason, %Boundary.Constructor{} = boundary, execution, trace),
    do: do_throw(reason, boundary.caller, execution, trace, true)

  defp throw_from_boundary(reason, %Boundary.Thenable{} = boundary, execution, trace) do
    execution =
      Promise.settle_assimilated(execution, boundary.promise, {:error, thrown(reason, trace)})

    {:idle, execution}
  end

  defp throw_from_boundary(reason, %Boundary.PromiseExecutor{} = boundary, execution, trace) do
    execution = Promise.settle(execution, boundary.promise, {:error, thrown(reason, trace)})
    {:complete, boundary.promise, boundary.caller, execution, boundary.tail?}
  end

  defp throw_from_boundary(
         reason,
         %Boundary.Iterator{consumer: :promise} = boundary,
         execution,
         trace
       ) do
    {reason, execution} = materialize(thrown(reason, trace), execution)
    execution = Promise.settle(execution, boundary.promise, {:error, reason})
    {:complete, boundary.promise, boundary.caller, execution, boundary.tail?}
  end

  defp throw_from_boundary(
         reason,
         %Boundary.Iterator{consumer: :set, caller: %Boundary.Constructor{} = constructor},
         execution,
         trace
       ),
       do: do_throw(reason, constructor.caller, execution, trace, true)

  defp throw_from_boundary(reason, %Boundary.Reaction{} = boundary, execution, trace) do
    execution = Promise.settle(execution, boundary.promise, {:error, thrown(reason, trace)})
    {:idle, execution}
  end

  defp throw_from_boundary(reason, %Native{caller: caller}, execution, trace),
    do: do_throw(reason, caller, execution, trace, true)

  defp throw_from_boundary(reason, %Frame{} = frame, execution, trace),
    do: do_throw(reason, frame, execution, trace, true)

  defp do_throw(reason, frame, execution, trace, caller?) do
    case split_at_catch(frame.stack) do
      {:caught, target, stack_below_catch} ->
        {:run, %{frame | pc: target, stack: [reason | stack_below_catch]}, execution}

      :uncaught ->
        trace = [stack_frame(frame, caller?) | trace]
        unwind_caller(reason, execution, trace)
    end
  end

  defp unwind_caller(reason, %State{callers: []} = execution, trace) do
    error = to_js_error(reason, execution, Enum.reverse(trace))
    {:error, error, execution}
  end

  defp unwind_caller(
         reason,
         %State{callers: [%Boundary.ObjectAssign{} = boundary | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    do_throw(reason, boundary.caller, execution, trace, true)
  end

  defp unwind_caller(
         reason,
         %State{callers: [%Boundary.ThenGetter{} = boundary | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    throw_from_boundary(reason, boundary, execution, trace)
  end

  defp unwind_caller(
         reason,
         %State{callers: [%Boundary.Accessor{} = boundary | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    do_throw(reason, boundary.caller, execution, trace, true)
  end

  defp unwind_caller(
         reason,
         %State{callers: [%Boundary.Constructor{} = boundary | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    do_throw(reason, boundary.caller, execution, trace, true)
  end

  defp unwind_caller(
         reason,
         %State{callers: [%Boundary.Thenable{} = boundary | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    throw_from_boundary(reason, boundary, execution, trace)
  end

  defp unwind_caller(
         reason,
         %State{callers: [%Boundary.PromiseExecutor{} = boundary | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    throw_from_boundary(reason, boundary, execution, trace)
  end

  defp unwind_caller(
         reason,
         %State{callers: [%Boundary.Iterator{} = boundary | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    throw_from_boundary(reason, boundary, execution, trace)
  end

  defp unwind_caller(
         reason,
         %State{callers: [%Boundary.Reaction{} = boundary | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    throw_from_boundary(reason, boundary, execution, trace)
  end

  defp unwind_caller(
         reason,
         %State{callers: [%Boundary.Async{} = boundary | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    {:async, Async.complete(boundary, {:error, thrown(reason, trace)}, execution)}
  end

  defp unwind_caller(
         reason,
         %State{callers: [%Native{} = native | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: execution.depth - 1}
    do_throw(reason, native.caller, execution, trace, true)
  end

  defp unwind_caller(
         reason,
         %State{callers: [%Frame{} = caller | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: execution.depth - 1}
    do_throw(reason, caller, execution, trace, true)
  end

  defp stack_frame(frame, caller?) do
    instruction_count = tuple_size(frame.function.instructions)
    pc = if caller?, do: frame.pc - 1, else: frame.pc
    pc = pc |> max(0) |> min(max(instruction_count - 1, 0))
    {line, column} = source_position(frame.function, pc)

    %{
      function: normalize_function_name(frame.function.name),
      filename: frame.function.filename,
      line: line,
      column: column
    }
  end

  defp source_position(%Function{source_positions: positions}, pc)
       when is_tuple(positions) and pc < tuple_size(positions),
       do: elem(positions, pc)

  defp source_position(%Function{line_num: line, col_num: column}, _pc),
    do: {line, column}

  defp normalize_function_name(name) when name in [nil, ""], do: "<anonymous>"

  defp normalize_function_name({:predefined, index}),
    do: AtomTable.lookup(index) || "<anonymous>"

  defp normalize_function_name(name) when is_binary(name), do: name
  defp normalize_function_name(name), do: inspect(name)

  defp split_at_catch(stack) do
    case Enum.split_while(stack, &(!match?({:catch, _target}, &1))) do
      {_discarded, [{:catch, target} | stack]} -> {:caught, target, stack}
      {_discarded, []} -> :uncaught
    end
  end

  defp thrown(reason, trace), do: %Thrown{value: reason, frames: Enum.reverse(trace)}

  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(value), do: Value.to_string_value(value)
end
