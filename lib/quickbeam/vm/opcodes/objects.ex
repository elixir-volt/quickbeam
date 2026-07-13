defmodule QuickBEAM.VM.Opcodes.Objects do
  @moduledoc """
  Executes object construction, property access, descriptors, and enumeration opcodes.

  Property behavior delegates to `QuickBEAM.VM.Properties`. Accessor-backed
  operations return explicit invocation actions so the interpreter can preserve
  resumable frames and JavaScript exception boundaries.
  """

  alias QuickBEAM.VM.{Execution, Frame, Heap, Properties, Reference, RegExp}
  alias QuickBEAM.VM.Opcodes.Locals

  @opcodes [
    :regexp,
    :special_object,
    :object,
    :array_from,
    :define_method,
    :define_field,
    :get_field,
    :get_field2,
    :get_array_el,
    :get_length,
    :put_field,
    :put_array_el,
    :delete,
    :for_in_start,
    :for_in_next
  ]

  @type action ::
          {:next, Frame.t(), Execution.t()}
          | {:throw, term(), Frame.t(), Execution.t()}
          | {:invoke_getter, term(), term(), Frame.t(), Execution.t()}
          | {:invoke_setter, term(), term(), term(), Frame.t(), Execution.t()}

  @doc "Returns the opcode names handled by this family."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes

  @doc "Executes one supported object or property opcode."
  @spec execute(atom(), [term()], Frame.t(), Execution.t()) :: action()
  def execute(:regexp, [], %{stack: [bytecode, source | stack]} = frame, execution),
    do: push(%{frame | stack: stack}, execution, %RegExp{source: source, bytecode: bytecode})

  def execute(:special_object, [type], frame, execution) when type in [0, 1] do
    values = Tuple.to_list(frame.args)
    {arguments, execution} = Heap.allocate(execution, :array)

    execution =
      values
      |> Enum.with_index()
      |> Enum.reduce(execution, fn {value, index}, execution ->
        {:ok, execution} =
          Properties.define(arguments, index, Locals.read_slot(value, execution), execution)

        execution
      end)

    push(frame, execution, arguments)
  end

  def execute(:special_object, [2], frame, execution),
    do: push(frame, execution, frame.callable)

  def execute(:special_object, [_type], frame, execution),
    do: push(frame, execution, :undefined)

  def execute(:object, [], frame, execution) do
    {reference, execution} = Heap.allocate(execution)
    push(frame, execution, reference)
  end

  def execute(:array_from, [count], frame, execution) do
    {elements, stack} = Enum.split(frame.stack, count)
    {reference, execution} = Heap.allocate(execution, :array)

    execution =
      elements
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(execution, fn {value, index}, execution ->
        {:ok, execution} = Properties.define(reference, index, value, execution)
        execution
      end)

    push(%{frame | stack: stack}, execution, reference)
  end

  def execute(
        :define_method,
        [atom, kind],
        %{stack: [callable, %Reference{} = object | stack]} = frame,
        execution
      ) do
    key = Locals.resolve_atom(atom, execution)

    result =
      case kind do
        4 -> Properties.define(object, key, callable, execution)
        5 -> Properties.define_accessor(object, key, :getter, callable, execution)
        6 -> Properties.define_accessor(object, key, :setter, callable, execution)
        _kind -> {:error, {:unsupported_method_kind, kind}}
      end

    case result do
      {:ok, execution} -> next(%{frame | stack: [object | stack]}, execution)
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(
        :define_field,
        [atom],
        %{stack: [value, %Reference{} = object | stack]} = frame,
        execution
      ) do
    key = Locals.resolve_atom(atom, execution)

    case Properties.define(object, key, value, execution) do
      {:ok, execution} -> next(%{frame | stack: [object | stack]}, execution)
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(:get_field, [atom], %{stack: [object | stack]} = frame, execution),
    do: get(object, Locals.resolve_atom(atom, execution), stack, frame, execution)

  def execute(:get_field2, [atom], %{stack: [object | stack]} = frame, execution),
    do: get(object, Locals.resolve_atom(atom, execution), [object | stack], frame, execution)

  def execute(:get_array_el, [], %{stack: [key, object | stack]} = frame, execution),
    do: get(object, key, stack, frame, execution)

  def execute(:get_length, [], %{stack: [object | stack]} = frame, execution),
    do: get(object, "length", stack, frame, execution)

  def execute(:put_field, [atom], %{stack: [value, object | stack]} = frame, execution),
    do:
      put(
        object,
        Locals.resolve_atom(atom, execution),
        value,
        stack,
        frame,
        execution
      )

  def execute(:put_array_el, [], %{stack: [value, key, object | stack]} = frame, execution),
    do: put(object, key, value, stack, frame, execution)

  def execute(:delete, [], %{stack: [key, %Reference{} = object | stack]} = frame, execution) do
    case Properties.delete(object, key, execution) do
      {:ok, deleted?, execution} -> next(%{frame | stack: [deleted? | stack]}, execution)
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(:for_in_start, [], %{stack: [object | stack]} = frame, execution) do
    case Properties.enumerable_keys(object, execution) do
      {:ok, keys} -> next(%{frame | stack: [{:for_in, keys, 0} | stack]}, execution)
      {:error, reason} -> {:throw, {:type_error, reason}, %{frame | stack: stack}, execution}
    end
  end

  def execute(:for_in_next, [], %{stack: [{:for_in, keys, index} | stack]} = frame, execution) do
    if index < length(keys) do
      iterator = {:for_in, keys, index + 1}
      next(%{frame | stack: [false, Enum.at(keys, index), iterator | stack]}, execution)
    else
      next(%{frame | stack: [true, :undefined, {:for_in, keys, index} | stack]}, execution)
    end
  end

  defp get(object, key, stack, frame, execution) do
    frame = %{frame | stack: stack}

    case Properties.get(object, key, execution) do
      {:ok, {:accessor, getter, receiver}} ->
        {:invoke_getter, getter, receiver, frame, execution}

      {:ok, value} ->
        next(%{frame | stack: [value | stack]}, execution)

      {:error, reason} ->
        {:throw, {:type_error, reason}, frame, execution}
    end
  end

  defp put(object, key, value, stack, frame, execution) do
    frame = %{frame | stack: stack}

    case Properties.put(object, key, value, execution) do
      {:ok, execution} ->
        next(frame, execution)

      {:error, {:invoke_setter, setter}} ->
        {:invoke_setter, setter, value, object, frame, execution}

      {:error, reason} ->
        {:throw, {:type_error, reason}, frame, execution}
    end
  end

  defp push(frame, execution, value), do: next(%{frame | stack: [value | frame.stack]}, execution)
  defp next(frame, execution), do: {:next, frame, execution}
end
