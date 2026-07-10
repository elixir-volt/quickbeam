defmodule QuickBEAM.VM.Interpreter do
  @moduledoc """
  Executes verified QuickJS bytecode with explicit JavaScript machine state.

  Frames, callers, exception unwinding, async boundaries, and native callback
  frames are represented as data so execution can suspend without retaining an
  Elixir or native call stack.
  """

  import Bitwise

  alias QuickBEAM.VM.{
    AccessorBoundary,
    AsyncBoundary,
    Builtins,
    Continuation,
    ConstructorBoundary,
    Coroutine,
    Execution,
    Export,
    Frame,
    Function,
    Heap,
    Memory,
    NativeFrame,
    ObjectAssignBoundary,
    Opcodes,
    PredefinedAtoms,
    Program,
    Promise,
    PromiseExecutorBoundary,
    PromiseReference,
    Reaction,
    ReactionBoundary,
    Reference,
    RegExp,
    ThenableBoundary,
    ThenGetterBoundary,
    Thrown,
    UTF16,
    Value
  }

  @default_max_steps 5_000_000
  @default_max_stack_depth 1_000

  @type result ::
          {:ok, term()}
          | {:error, term()}
          | {:suspended, Continuation.t()}

  @spec eval(Program.t(), keyword()) :: result()
  def eval(%Program{} = program, opts \\ []), do: program |> start(opts) |> finish()

  @doc "Starts interpreting a program and returns its raw machine result."
  def start(%Program{} = program, opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)

    vars = Map.new(Keyword.get(opts, :vars, %{}))

    execution = %Execution{
      atoms: program.atoms,
      globals: vars,
      handlers: Map.new(Keyword.get(opts, :handlers, %{})),
      max_stack_depth: Keyword.get(opts, :max_stack_depth, @default_max_stack_depth),
      memory_limit: Keyword.get(opts, :memory_limit, :infinity),
      remaining_steps: max_steps,
      step_limit: max_steps
    }

    execution = Memory.charge(execution, Memory.estimate(vars))
    execution = install_host_globals(execution)
    frame = new_frame(program.root, program.root, [], :undefined, {})
    run(frame, execution)
  end

  @spec resume(Continuation.t(), {:ok, term()} | {:error, term()}) :: result()
  def resume(%Continuation{} = continuation, result),
    do: continuation |> resume_raw(result) |> finish()

  @doc "Resumes a legacy continuation without exporting the resulting value."
  def resume_raw(%Continuation{} = continuation, {:ok, value}) do
    frame = %{continuation.frame | stack: [value | continuation.frame.stack]}
    run(frame, continuation.execution)
  end

  def resume_raw(%Continuation{} = continuation, {:error, reason}) do
    raise_js_from_caller(reason, continuation.frame, continuation.execution)
  end

  @doc "Resumes a detached async coroutine with a Promise settlement."
  def resume_coroutine(%Coroutine{} = coroutine, result, %Execution{} = execution) do
    callers = coroutine.callers ++ [coroutine.boundary]
    frame_depth = Enum.count(coroutine.callers, &match?(%Frame{}, &1))
    execution = %{execution | callers: callers, depth: coroutine.boundary.depth + frame_depth + 1}

    case result do
      {:ok, value} -> run(%{coroutine.frame | stack: [value | coroutine.frame.stack]}, execution)
      {:error, reason} -> raise_js_from_caller(reason, coroutine.frame, execution)
    end
  end

  @doc "Reads a thenable's accessor-backed `then` property during Promise resolution."
  def read_thenable(promise, thenable, getter, %Execution{} = execution),
    do: start_then_getter(promise, thenable, getter, nil, execution)

  @doc "Runs one pending synchronous Promise-resolution job, when present."
  def run_synchronous_job(%Execution{} = execution) do
    case :queue.out(execution.sync_jobs) do
      {{:value, {:read_thenable, promise, thenable, getter}}, sync_jobs} ->
        execution = %{execution | sync_jobs: sync_jobs}
        start_then_getter(promise, thenable, getter, nil, execution)

      {:empty, _sync_jobs} ->
        {:none, execution}
    end
  end

  defp start_then_getter(promise, thenable, getter, continuation, execution) do
    boundary = %ThenGetterBoundary{
      promise: promise,
      thenable: thenable,
      depth: execution.depth,
      continuation: continuation
    }

    dispatch_call(getter, [], thenable, boundary, execution, false)
  end

  @doc "Invokes a thenable and connects its resolver functions to a Promise."
  def assimilate_thenable(promise, thenable, callable, %Execution{} = execution) do
    boundary = %ThenableBoundary{promise: promise, depth: execution.depth}
    resolve = {:promise_resolver, promise, :resolve_assimilated}
    reject = {:promise_resolver, promise, :reject_assimilated}
    dispatch_call(callable, [resolve, reject], thenable, boundary, execution, false)
  end

  @doc "Runs one queued Promise reaction against a source settlement."
  def run_reaction(%Reaction{} = reaction, result, %Execution{} = execution) do
    callback =
      case result do
        {:ok, _value} -> reaction.on_fulfilled
        {:error, _reason} -> reaction.on_rejected
      end

    if type_of(callback, execution) == "function" do
      boundary = %ReactionBoundary{
        promise: reaction.result_promise,
        depth: execution.depth,
        mode: reaction.kind,
        original_result: result
      }

      arguments = if reaction.kind == :finally, do: [], else: [reaction_argument(result)]
      dispatch_call(callback, arguments, :undefined, boundary, execution, false)
    else
      execution = Promise.settle(execution, reaction.result_promise, result)
      {:idle, execution}
    end
  end

  defp reaction_argument({:ok, value}), do: value
  defp reaction_argument({:error, %Thrown{value: value}}), do: value
  defp reaction_argument({:error, reason}), do: reason

  @doc "Converts a raw machine result into the interpreter's public result."
  def finish({:ok, value, execution}), do: Export.value(value, execution)
  def finish({:error, reason, _execution}), do: {:error, reason}
  def finish({:suspended, continuation}), do: {:suspended, continuation}
  def finish({:idle, _execution}), do: {:error, :idle_evaluation}

  defp enter_call(callable, args, this, caller, execution, tail?, frame_callable \\ nil) do
    with {:ok, function, closure_refs} <- callable_parts(callable) do
      frame_callable = frame_callable || callable

      if function.func_kind == 2 do
        enter_async_call(
          function,
          frame_callable,
          closure_refs,
          args,
          this,
          caller,
          execution,
          tail?
        )
      else
        enter_sync_call(
          function,
          frame_callable,
          closure_refs,
          args,
          this,
          caller,
          execution,
          tail?
        )
      end
    else
      {:error, reason} -> raise_js_from_caller(reason, caller, execution)
    end
  end

  defp enter_sync_call(function, callable, closure_refs, args, this, caller, execution, tail?) do
    depth = if tail?, do: execution.depth, else: execution.depth + 1

    if depth > execution.max_stack_depth do
      {:error, {:limit_exceeded, :stack_depth, depth}, execution}
    else
      execution =
        if tail?,
          do: execution,
          else: %{execution | callers: [caller | execution.callers], depth: depth}

      run(new_frame(function, callable, args, this, closure_refs), execution)
    end
  end

  defp enter_async_call(function, callable, closure_refs, args, this, caller, execution, tail?) do
    depth = if tail?, do: execution.depth, else: execution.depth + 1

    if depth > execution.max_stack_depth do
      {:error, {:limit_exceeded, :stack_depth, depth}, execution}
    else
      {promise, execution} = Promise.new(execution)

      mode =
        cond do
          match?(%ReactionBoundary{}, caller) -> :reaction
          match?(%PromiseExecutorBoundary{}, caller) -> :executor
          match?(%ThenableBoundary{}, caller) -> :thenable
          tail? -> :return
          true -> :push
        end

      boundary = %AsyncBoundary{
        promise: promise,
        caller: if(tail?, do: nil, else: caller),
        depth: execution.depth,
        mode: mode
      }

      execution = %{execution | callers: [boundary | execution.callers], depth: depth}
      run(new_frame(function, callable, args, this, closure_refs), execution)
    end
  end

  defp callable_parts(%Function{} = function), do: {:ok, function, {}}

  defp callable_parts({:closure, %Function{} = function, closure_refs}),
    do: {:ok, function, closure_refs}

  defp callable_parts(value), do: {:error, {:not_callable, value}}

  defp new_frame(function, callable, args, this, closure_refs) do
    local_count = max(function.arg_count + function.var_count, 1)

    %Frame{
      function: function,
      callable: callable,
      closure_refs: closure_refs,
      locals: :erlang.make_tuple(local_count, :undefined),
      args: List.to_tuple(args),
      this: this
    }
  end

  defp run(frame, %Execution{} = execution) when execution.sync_jobs != {[], []} do
    case :queue.out(execution.sync_jobs) do
      {{:value, {:read_thenable, promise, thenable, getter}}, sync_jobs} ->
        execution = %{execution | sync_jobs: sync_jobs}
        start_then_getter(promise, thenable, getter, frame, execution)

      {:empty, _sync_jobs} ->
        run(frame, %{execution | sync_jobs: {[], []}})
    end
  end

  defp run(_frame, %Execution{memory_exceeded: true} = execution),
    do: {:error, {:limit_exceeded, :memory_bytes, execution.memory_limit}, execution}

  defp run(_frame, %Execution{remaining_steps: 0} = execution),
    do: {:error, {:limit_exceeded, :steps, execution.step_limit}, execution}

  defp run(%Frame{pc: pc, function: function}, execution)
       when pc >= tuple_size(function.instructions),
       do: {:error, {:invalid_program_counter, pc}, execution}

  defp run(%Frame{} = frame, %Execution{} = execution) do
    {opcode, operands} = elem(frame.function.instructions, frame.pc)
    {name, _size, _pops, _pushes, _format} = Opcodes.info(opcode)
    {name, operands} = Opcodes.expand_short_form(name, operands, frame.function.arg_count)
    execution = %{execution | remaining_steps: execution.remaining_steps - 1}
    execute(name, operands, frame, execution)
  end

  defp execute(:push_i32, [value], frame, execution), do: push(frame, execution, value)
  defp execute(:push_i8, [value], frame, execution), do: push(frame, execution, value)
  defp execute(:push_i16, [value], frame, execution), do: push(frame, execution, value)
  defp execute(:undefined, [], frame, execution), do: push(frame, execution, :undefined)
  defp execute(:null, [], frame, execution), do: push(frame, execution, nil)
  defp execute(:push_false, [], frame, execution), do: push(frame, execution, false)
  defp execute(:push_true, [], frame, execution), do: push(frame, execution, true)

  defp execute(:push_bigint_i32, [value], frame, execution),
    do: push(frame, execution, {:bigint, value})

  defp execute(:push_const, [index], frame, execution),
    do: push(frame, execution, Enum.at(frame.function.constants, index))

  defp execute(:push_const8, [index], frame, execution),
    do: execute(:push_const, [index], frame, execution)

  defp execute(:push_atom_value, [atom], frame, execution),
    do: push(frame, execution, resolve_atom(atom, execution))

  defp execute(:push_this, [], frame, execution), do: push(frame, execution, frame.this)

  defp execute(:regexp, [], %{stack: [bytecode, source | stack]} = frame, execution) do
    push(%{frame | stack: stack}, execution, %RegExp{source: source, bytecode: bytecode})
  end

  defp execute(:special_object, [type], frame, execution) when type in [0, 1] do
    values = Tuple.to_list(frame.args)
    {arguments, execution} = Heap.allocate(execution, :array)

    execution =
      values
      |> Enum.with_index()
      |> Enum.reduce(execution, fn {value, index}, execution ->
        {:ok, execution} = Heap.define(execution, arguments, index, read_slot(value, execution))
        execution
      end)

    push(frame, execution, arguments)
  end

  defp execute(:special_object, [2], frame, execution),
    do: push(frame, execution, frame.callable)

  defp execute(:special_object, [_type], frame, execution),
    do: push(frame, execution, :undefined)

  defp execute(:object, [], frame, execution) do
    {reference, execution} = Heap.allocate(execution)
    push(frame, execution, reference)
  end

  defp execute(:array_from, [count], frame, execution) do
    {elements, stack} = Enum.split(frame.stack, count)
    {reference, execution} = Heap.allocate(execution, :array)

    execution =
      elements
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(execution, fn {value, index}, execution ->
        {:ok, execution} = Heap.define(execution, reference, index, value)
        execution
      end)

    push(%{frame | stack: stack}, execution, reference)
  end

  defp execute(
         :define_method,
         [atom, kind],
         %{stack: [callable, %Reference{} = object | stack]} = frame,
         execution
       ) do
    key = resolve_atom(atom, execution)

    result =
      case kind do
        4 -> Heap.define(execution, object, key, callable)
        5 -> Heap.define_accessor(execution, object, key, :getter, callable)
        6 -> Heap.define_accessor(execution, object, key, :setter, callable)
        _kind -> {:error, {:unsupported_method_kind, kind}}
      end

    case result do
      {:ok, execution} -> continue(%{frame | stack: [object | stack]}, execution)
      {:error, reason} -> raise_js({:type_error, reason}, frame, execution)
    end
  end

  defp execute(
         :define_field,
         [atom],
         %{stack: [value, %Reference{} = object | stack]} = frame,
         execution
       ) do
    key = resolve_atom(atom, execution)

    case Heap.define(execution, object, key, value) do
      {:ok, execution} -> continue(%{frame | stack: [object | stack]}, execution)
      {:error, reason} -> raise_js({:type_error, reason}, frame, execution)
    end
  end

  defp execute(:get_field, [atom], %{stack: [object | stack]} = frame, execution) do
    get_property_and_continue(object, resolve_atom(atom, execution), stack, frame, execution)
  end

  defp execute(:get_field2, [atom], %{stack: [object | stack]} = frame, execution) do
    get_property_and_continue(
      object,
      resolve_atom(atom, execution),
      [object | stack],
      frame,
      execution
    )
  end

  defp execute(:get_array_el, [], %{stack: [key, object | stack]} = frame, execution) do
    get_property_and_continue(object, key, stack, frame, execution)
  end

  defp execute(:get_length, [], %{stack: [object | stack]} = frame, execution) do
    get_property_and_continue(object, "length", stack, frame, execution)
  end

  defp execute(:put_field, [atom], %{stack: [value, object | stack]} = frame, execution) do
    put_property_and_continue(
      object,
      resolve_atom(atom, execution),
      value,
      stack,
      frame,
      execution
    )
  end

  defp execute(:put_array_el, [], %{stack: [value, key, object | stack]} = frame, execution) do
    put_property_and_continue(object, key, value, stack, frame, execution)
  end

  defp execute(:delete, [], %{stack: [key, %Reference{} = object | stack]} = frame, execution) do
    case Heap.delete(execution, object, key) do
      {:ok, deleted?, execution} -> continue(%{frame | stack: [deleted? | stack]}, execution)
      {:error, reason} -> raise_js({:type_error, reason}, frame, execution)
    end
  end

  defp execute(:to_propkey, [], frame, execution), do: continue(frame, execution)

  defp execute(:to_object, [], %{stack: [value | _]} = frame, execution)
       when value in [nil, :undefined],
       do: raise_js({:type_error, :cannot_convert_to_object}, frame, execution)

  defp execute(:to_object, [], frame, execution), do: continue(frame, execution)

  defp execute(:is_undefined_or_null, [], frame, execution),
    do: unary(frame, execution, &(&1 in [:undefined, nil]))

  defp execute(:is_undefined, [], frame, execution),
    do: unary(frame, execution, &(&1 == :undefined))

  defp execute(:is_null, [], frame, execution),
    do: unary(frame, execution, &is_nil/1)

  defp execute(:is_function, [], %{stack: [value | stack]} = frame, execution),
    do: continue(%{frame | stack: [type_of(value, execution) == "function" | stack]}, execution)

  defp execute(:drop, [], %{stack: [_value | stack]} = frame, execution),
    do: continue(%{frame | stack: stack}, execution)

  defp execute(:dup, [], %{stack: [value | _]} = frame, execution),
    do: continue(%{frame | stack: [value | frame.stack]}, execution)

  defp execute(:dup1, [], %{stack: [a, b | stack]} = frame, execution),
    do: continue(%{frame | stack: [a, b, b | stack]}, execution)

  defp execute(:dup2, [], %{stack: [a, b | stack]} = frame, execution),
    do: continue(%{frame | stack: [a, b, a, b | stack]}, execution)

  defp execute(:dup3, [], %{stack: [a, b, c | stack]} = frame, execution),
    do: continue(%{frame | stack: [a, b, c, a, b, c | stack]}, execution)

  defp execute(:nip, [], %{stack: [a, _b | stack]} = frame, execution),
    do: continue(%{frame | stack: [a | stack]}, execution)

  defp execute(:nip_catch, [], frame, execution),
    do: execute(:nip, [], frame, execution)

  defp execute(:nip1, [], %{stack: [a, b, _c | stack]} = frame, execution),
    do: continue(%{frame | stack: [a, b | stack]}, execution)

  defp execute(:swap, [], %{stack: [a, b | stack]} = frame, execution),
    do: continue(%{frame | stack: [b, a | stack]}, execution)

  defp execute(:swap2, [], %{stack: [a, b, c, d | stack]} = frame, execution),
    do: continue(%{frame | stack: [c, d, a, b | stack]}, execution)

  defp execute(:perm3, [], %{stack: [a, b, c | stack]} = frame, execution),
    do: continue(%{frame | stack: [a, c, b | stack]}, execution)

  defp execute(:perm4, [], %{stack: [a, b, c, d | stack]} = frame, execution),
    do: continue(%{frame | stack: [a, c, d, b | stack]}, execution)

  defp execute(:perm5, [], %{stack: [a, b, c, d, e | stack]} = frame, execution),
    do: continue(%{frame | stack: [a, c, d, e, b | stack]}, execution)

  defp execute(:rot3l, [], %{stack: [a, b, c | stack]} = frame, execution),
    do: continue(%{frame | stack: [c, a, b | stack]}, execution)

  defp execute(:rot3r, [], %{stack: [a, b, c | stack]} = frame, execution),
    do: continue(%{frame | stack: [b, c, a | stack]}, execution)

  defp execute(:rot4l, [], %{stack: [a, b, c, d | stack]} = frame, execution),
    do: continue(%{frame | stack: [d, a, b, c | stack]}, execution)

  defp execute(:rot5l, [], %{stack: [a, b, c, d, e | stack]} = frame, execution),
    do: continue(%{frame | stack: [e, a, b, c, d | stack]}, execution)

  defp execute(:insert2, [], %{stack: [a, b | stack]} = frame, execution),
    do: continue(%{frame | stack: [a, b, a | stack]}, execution)

  defp execute(:insert3, [], %{stack: [a, b, c | stack]} = frame, execution),
    do: continue(%{frame | stack: [a, b, c, a | stack]}, execution)

  defp execute(:get_arg, [index], frame, execution),
    do: push(frame, execution, read_slot(tuple_get(frame.args, index), execution))

  defp execute(:put_arg, [index], %{stack: [value | stack]} = frame, execution) do
    {args, execution} = write_tuple_slot(frame.args, index, value, execution)
    continue(%{frame | args: args, stack: stack}, execution)
  end

  defp execute(:set_arg, [index], %{stack: [value | _]} = frame, execution) do
    {args, execution} = write_tuple_slot(frame.args, index, value, execution)
    continue(%{frame | args: args}, execution)
  end

  defp execute(:get_loc, [index], frame, execution),
    do: push(frame, execution, read_slot(elem(frame.locals, index), execution))

  defp execute(:get_loc0_loc1, [first, second], frame, execution) do
    first = read_slot(elem(frame.locals, first), execution)
    second = read_slot(elem(frame.locals, second), execution)
    continue(%{frame | stack: [first, second | frame.stack]}, execution)
  end

  defp execute(:put_loc, [index], %{stack: [value | stack]} = frame, execution) do
    {locals, execution} = write_tuple_slot(frame.locals, index, value, execution)
    continue(%{frame | locals: locals, stack: stack}, execution)
  end

  defp execute(:set_loc, [index], %{stack: [value | _]} = frame, execution) do
    {locals, execution} = write_tuple_slot(frame.locals, index, value, execution)
    continue(%{frame | locals: locals}, execution)
  end

  defp execute(:set_loc_uninitialized, [index], frame, execution) do
    {locals, execution} = write_tuple_slot(frame.locals, index, :uninitialized, execution)
    continue(%{frame | locals: locals}, execution)
  end

  defp execute(:get_loc_check, [index], frame, execution) do
    case read_slot(elem(frame.locals, index), execution) do
      :uninitialized -> raise_js({:reference_error, index}, frame, execution)
      value -> push(frame, execution, value)
    end
  end

  defp execute(:put_loc_check_init, [index], frame, execution),
    do: execute(:put_loc, [index], frame, execution)

  defp execute(:put_loc_check, [index], frame, execution),
    do: execute(:put_loc, [index], frame, execution)

  defp execute(:close_loc, [_index], frame, execution), do: continue(frame, execution)

  defp execute(:inc_loc, [index], frame, execution),
    do: update_local(frame, execution, index, &Value.add(&1, 1))

  defp execute(:dec_loc, [index], frame, execution),
    do: update_local(frame, execution, index, &Value.subtract(&1, 1))

  defp execute(:add_loc, [index], %{stack: [value | stack]} = frame, execution) do
    current = read_slot(elem(frame.locals, index), execution)

    {locals, execution} =
      write_tuple_slot(frame.locals, index, Value.add(current, value), execution)

    continue(%{frame | locals: locals, stack: stack}, execution)
  end

  defp execute(:for_in_start, [], %{stack: [object | stack]} = frame, execution) do
    case enumerable_keys(object, execution) do
      {:ok, keys} -> continue(%{frame | stack: [{:for_in, keys, 0} | stack]}, execution)
      {:error, reason} -> raise_js({:type_error, reason}, %{frame | stack: stack}, execution)
    end
  end

  defp execute(:for_in_next, [], %{stack: [{:for_in, keys, index} | stack]} = frame, execution) do
    if index < length(keys) do
      iterator = {:for_in, keys, index + 1}
      continue(%{frame | stack: [false, Enum.at(keys, index), iterator | stack]}, execution)
    else
      continue(%{frame | stack: [true, :undefined, {:for_in, keys, index} | stack]}, execution)
    end
  end

  defp execute(:catch, [target], frame, execution) do
    continue(%{frame | stack: [{:catch, target} | frame.stack]}, execution)
  end

  defp execute(:gosub, [target], frame, execution) do
    return_address = {:return_address, frame.pc + 1}
    run(%{frame | pc: target, stack: [return_address | frame.stack]}, execution)
  end

  defp execute(:ret, [], %{stack: [{:return_address, target} | stack]} = frame, execution),
    do: run(%{frame | pc: target, stack: stack}, execution)

  defp execute(:if_false, [target], %{stack: [value | stack]} = frame, execution) do
    pc = if Value.truthy?(value), do: frame.pc + 1, else: target
    run(%{frame | pc: pc, stack: stack}, execution)
  end

  defp execute(:if_false8, [target], frame, execution),
    do: execute(:if_false, [target], frame, execution)

  defp execute(:if_true, [target], %{stack: [value | stack]} = frame, execution) do
    pc = if Value.truthy?(value), do: target, else: frame.pc + 1
    run(%{frame | pc: pc, stack: stack}, execution)
  end

  defp execute(:if_true8, [target], frame, execution),
    do: execute(:if_true, [target], frame, execution)

  defp execute(:goto, [target], frame, execution), do: run(%{frame | pc: target}, execution)
  defp execute(:goto8, [target], frame, execution), do: execute(:goto, [target], frame, execution)

  defp execute(:goto16, [target], frame, execution),
    do: execute(:goto, [target], frame, execution)

  defp execute(:return, [], %{stack: [value | _stack]}, execution),
    do: return_value(value, execution)

  defp execute(:return_undef, [], _frame, execution),
    do: return_value(:undefined, execution)

  defp execute(:return_async, [], %{stack: [value | _stack]}, execution),
    do: complete_async(value, execution)

  defp execute(:add, [], frame, execution), do: binary(frame, execution, &Value.add/2)
  defp execute(:sub, [], frame, execution), do: binary(frame, execution, &Value.subtract/2)
  defp execute(:mul, [], frame, execution), do: binary(frame, execution, &Value.multiply/2)
  defp execute(:div, [], frame, execution), do: binary(frame, execution, &Value.divide/2)
  defp execute(:mod, [], frame, execution), do: binary(frame, execution, &Value.modulo/2)
  defp execute(:pow, [], frame, execution), do: binary(frame, execution, &Value.power/2)
  defp execute(:lt, [], frame, execution), do: compare(frame, execution, &Kernel.</2)
  defp execute(:lte, [], frame, execution), do: compare(frame, execution, &Kernel.<=/2)
  defp execute(:gt, [], frame, execution), do: compare(frame, execution, &Kernel.>/2)
  defp execute(:gte, [], frame, execution), do: compare(frame, execution, &Kernel.>=/2)
  defp execute(:eq, [], frame, execution), do: binary(frame, execution, &Value.abstract_equal?/2)

  defp execute(:neq, [], frame, execution),
    do: binary(frame, execution, &(not Value.abstract_equal?(&1, &2)))

  defp execute(:strict_eq, [], frame, execution),
    do: binary(frame, execution, &Value.strict_equal?/2)

  defp execute(:strict_neq, [], frame, execution),
    do: binary(frame, execution, &(not Value.strict_equal?(&1, &2)))

  defp execute(:in, [], %{stack: [object, key | stack]} = frame, execution) do
    continue(%{frame | stack: [has_property?(object, key, execution) | stack]}, execution)
  end

  defp execute(
         :instanceof,
         [],
         %{stack: [constructor, object | stack]} = frame,
         execution
       ) do
    with "function" <- type_of(constructor, execution),
         {:ok, %Reference{} = prototype} <- instanceof_prototype(constructor, execution) do
      result =
        is_struct(object, Reference) and
          Heap.prototype_chain_contains?(execution, object, prototype)

      continue(%{frame | stack: [result | stack]}, execution)
    else
      _invalid -> raise_js({:type_error, :invalid_instanceof_target}, frame, execution)
    end
  end

  defp execute(:and, [], frame, execution), do: bitwise(frame, execution, &band/2)
  defp execute(:or, [], frame, execution), do: bitwise(frame, execution, &bor/2)
  defp execute(:xor, [], frame, execution), do: bitwise(frame, execution, &bxor/2)
  defp execute(:shl, [], frame, execution), do: binary(frame, execution, &Value.shift_left/2)
  defp execute(:sar, [], frame, execution), do: binary(frame, execution, &Value.shift_right/2)

  defp execute(:shr, [], frame, execution),
    do: binary(frame, execution, &Value.shift_right_unsigned/2)

  defp execute(:neg, [], frame, execution), do: unary(frame, execution, &Value.negate/1)
  defp execute(:plus, [], frame, execution), do: unary(frame, execution, &Value.to_number/1)
  defp execute(:not, [], frame, execution), do: unary(frame, execution, &Value.bitwise_not/1)
  defp execute(:lnot, [], frame, execution), do: unary(frame, execution, &(not Value.truthy?(&1)))

  defp execute(:typeof, [], %{stack: [value | stack]} = frame, execution) do
    continue(%{frame | stack: [type_of(value, execution) | stack]}, execution)
  end

  defp execute(:typeof_is_function, [], %{stack: [value | stack]} = frame, execution) do
    continue(%{frame | stack: [type_of(value, execution) == "function" | stack]}, execution)
  end

  defp execute(:typeof_is_undefined, [], frame, execution),
    do: unary(frame, execution, &(&1 == :undefined))

  defp execute(:inc, [], frame, execution), do: unary(frame, execution, &Value.add(&1, 1))
  defp execute(:dec, [], frame, execution), do: unary(frame, execution, &Value.subtract(&1, 1))

  defp execute(:post_inc, [], %{stack: [value | stack]} = frame, execution) do
    continue(%{frame | stack: [Value.add(value, 1), value | stack]}, execution)
  end

  defp execute(:post_dec, [], %{stack: [value | stack]} = frame, execution) do
    continue(%{frame | stack: [Value.subtract(value, 1), value | stack]}, execution)
  end

  defp execute(:fclosure, [index], frame, execution) do
    function = Enum.at(frame.function.constants, index)
    {callable, frame, execution} = capture_closure(function, frame, execution)
    {reference, execution} = allocate_function(callable, function, execution)
    push(frame, execution, reference)
  end

  defp execute(:fclosure8, [index], frame, execution),
    do: execute(:fclosure, [index], frame, execution)

  defp execute(:call, [argument_count], frame, execution),
    do: call(frame, execution, argument_count, false)

  defp execute(:tail_call, [argument_count], frame, execution),
    do: call(frame, execution, argument_count, true)

  defp execute(:call_method, [argument_count], frame, execution),
    do: call_method(frame, execution, argument_count, false)

  defp execute(:tail_call_method, [argument_count], frame, execution),
    do: call_method(frame, execution, argument_count, true)

  defp execute(:call_constructor, [argument_count], frame, execution),
    do: call_constructor(frame, execution, argument_count)

  defp execute(name, [index], frame, execution)
       when name in [
              :get_var_ref,
              :get_var_ref0,
              :get_var_ref1,
              :get_var_ref2,
              :get_var_ref3,
              :get_var_ref_check
            ] do
    value = read_reference(elem(frame.closure_refs, index), execution)

    if name == :get_var_ref_check and value == :uninitialized,
      do: raise_js({:reference_error, index}, frame, execution),
      else: push(frame, execution, value)
  end

  defp execute(name, [index], %{stack: [value | stack]} = frame, execution)
       when name in [
              :put_var_ref,
              :put_var_ref0,
              :put_var_ref1,
              :put_var_ref2,
              :put_var_ref3,
              :put_var_ref_check,
              :put_var_ref_check_init
            ] do
    execution = write_reference(elem(frame.closure_refs, index), value, execution)
    continue(%{frame | stack: stack}, execution)
  end

  defp execute(:set_var_ref, [index], %{stack: [value | _]} = frame, execution) do
    execution = write_reference(elem(frame.closure_refs, index), value, execution)
    continue(frame, execution)
  end

  defp execute(:get_var, [atom], frame, execution) do
    name = resolve_atom(atom, execution)

    case Map.fetch(execution.globals, name) do
      {:ok, value} -> push(frame, execution, value)
      :error -> raise_js({:reference_error, name}, frame, execution)
    end
  end

  defp execute(:get_var_undef, [atom], frame, execution) do
    name = resolve_atom(atom, execution)
    push(frame, execution, Map.get(execution.globals, name, :undefined))
  end

  defp execute(name, [atom | _flags], %{stack: [value | stack]} = frame, execution)
       when name in [:put_var, :put_var_init, :define_func] do
    name = resolve_atom(atom, execution)
    execution = %{execution | globals: Map.put(execution.globals, name, value)}
    continue(%{frame | stack: stack}, execution)
  end

  defp execute(name, [_atom | _flags], frame, execution)
       when name in [:define_var, :check_define_var],
       do: continue(frame, execution)

  defp execute(:throw, [], %{stack: [value | stack]} = frame, execution),
    do: raise_js(value, %{frame | stack: stack}, execution)

  defp execute(:await, [], %{stack: [%PromiseReference{} = promise | stack]} = frame, execution) do
    frame = %{frame | stack: stack}

    case detach_async(frame, execution, promise) do
      {:ok, result} -> result
      :no_async_boundary -> suspend_promise_legacy(frame, execution, promise)
    end
  end

  defp execute(:await, [], %{stack: [{:pending, reference} | stack]} = frame, execution) do
    continuation = %Continuation{
      frame: next_frame(%{frame | stack: stack}),
      execution: execution,
      awaiting: reference
    }

    {:suspended, continuation}
  end

  defp execute(:await, [], %{stack: [{:resolved, value} | stack]} = frame, execution),
    do: await_immediate({:ok, value}, %{frame | stack: stack}, execution)

  defp execute(:await, [], %{stack: [{:rejected, reason} | stack]} = frame, execution),
    do: await_immediate({:error, reason}, %{frame | stack: stack}, execution)

  defp execute(:await, [], %{stack: [value | stack]} = frame, execution),
    do: await_immediate({:ok, value}, %{frame | stack: stack}, execution)

  defp execute(name, _operands, frame, execution)
       when name in [:nop, :set_name, :set_name_computed, :check_ctor, :close_loc],
       do: continue(frame, execution)

  defp execute(name, operands, _frame, execution),
    do: {:error, {:unsupported_opcode, name, operands}, execution}

  defp call(%Frame{stack: stack} = frame, execution, argument_count, tail?) do
    {arguments, callable_and_rest} = Enum.split(stack, argument_count)

    case callable_and_rest do
      [callable | rest] ->
        caller = %{next_frame(frame) | stack: rest}
        dispatch_call(callable, Enum.reverse(arguments), :undefined, caller, execution, tail?)

      _ ->
        {:error, {:invalid_stack, :call}, execution}
    end
  end

  defp call_method(%Frame{stack: stack} = frame, execution, argument_count, tail?) do
    {arguments, callable_and_this} = Enum.split(stack, argument_count)

    case callable_and_this do
      [callable, this | rest] ->
        caller = %{next_frame(frame) | stack: rest}
        dispatch_call(callable, Enum.reverse(arguments), this, caller, execution, tail?)

      _ ->
        {:error, {:invalid_stack, :call_method}, execution}
    end
  end

  defp call_constructor(%Frame{stack: stack} = frame, execution, argument_count) do
    {arguments, constructor_and_new_target} = Enum.split(stack, argument_count)

    case constructor_and_new_target do
      [_new_target, constructor | rest] ->
        if constructable?(constructor, execution) do
          caller = %{next_frame(frame) | stack: rest}
          prototype = constructor_prototype(constructor, execution)
          {instance, execution} = Heap.allocate(execution, :ordinary, prototype: prototype)

          boundary = %ConstructorBoundary{
            instance: instance,
            caller: caller,
            depth: execution.depth
          }

          dispatch_call(
            constructor,
            Enum.reverse(arguments),
            instance,
            boundary,
            execution,
            false
          )
        else
          raise_js({:type_error, :not_a_constructor}, frame, execution)
        end

      _ ->
        {:error, {:invalid_stack, :call_constructor}, execution}
    end
  end

  defp constructable?(%Reference{} = constructor, execution) do
    case Builtins.callable(execution, constructor) do
      nil -> false
      callable -> constructable?(callable, execution)
    end
  end

  defp constructable?(%Function{has_prototype: has_prototype}, _execution), do: has_prototype

  defp constructable?({:closure, %Function{has_prototype: has_prototype}, _refs}, _execution),
    do: has_prototype

  defp constructable?({:bound_function, target, _this, _arguments}, execution),
    do: constructable?(target, execution)

  defp constructable?({:builtin, name}, _execution),
    do: name in ["Array", "Error", "Object", "Promise", "Set", "String"]

  defp constructable?(_constructor, _execution), do: false

  defp constructor_prototype({:bound_function, target, _this, _arguments}, execution),
    do: constructor_prototype(target, execution)

  defp constructor_prototype(constructor, execution) do
    case get_property(constructor, "prototype", execution) do
      {:ok, %Reference{} = prototype} -> prototype
      _other -> nil
    end
  end

  defp instanceof_prototype({:bound_function, target, _this, _arguments}, execution),
    do: instanceof_prototype(target, execution)

  defp instanceof_prototype(constructor, execution),
    do: get_property(constructor, "prototype", execution)

  defp dispatch_call({:host_function, :beam_call}, arguments, _this, caller, execution, tail?),
    do: start_host_call(arguments, caller, execution, tail?)

  defp dispatch_call({:builtin, "Promise"}, [executor | _], _this, caller, execution, tail?) do
    {promise, execution} = Promise.new(execution)

    boundary = %PromiseExecutorBoundary{
      promise: promise,
      caller: caller,
      depth: execution.depth,
      tail?: tail?
    }

    resolve = {:promise_resolver, promise, :resolve}
    reject = {:promise_resolver, promise, :reject}

    if type_of(executor, execution) == "function" do
      dispatch_call(executor, [resolve, reject], :undefined, boundary, execution, false)
    else
      execution =
        Promise.settle(
          execution,
          promise,
          {:error, {:type_error, :promise_executor_not_callable}}
        )

      complete_executor(boundary, execution)
    end
  end

  defp dispatch_call({:builtin, "Promise"}, _arguments, _this, caller, execution, tail?) do
    {promise, execution} = Promise.new(execution)

    execution =
      Promise.settle(execution, promise, {:error, {:type_error, :missing_promise_executor}})

    complete_call_result(promise, caller, execution, tail?)
  end

  defp dispatch_call(
         {:promise_resolver, promise, kind},
         arguments,
         _this,
         caller,
         execution,
         tail?
       ) do
    value = Enum.at(arguments, 0, :undefined)

    result =
      if kind in [:resolve, :resolve_assimilated], do: {:ok, value}, else: {:error, value}

    execution =
      if kind in [:resolve_assimilated, :reject_assimilated] do
        Promise.settle_assimilated(execution, promise, result)
      else
        Promise.settle(execution, promise, result)
      end

    complete_call_result(:undefined, caller, execution, tail?)
  end

  defp dispatch_call(
         {:bound_function, target, _bound_this, bound_arguments},
         arguments,
         this,
         %ConstructorBoundary{} = caller,
         execution,
         tail?
       ),
       do: dispatch_call(target, bound_arguments ++ arguments, this, caller, execution, tail?)

  defp dispatch_call(
         {:bound_function, target, bound_this, bound_arguments},
         arguments,
         _this,
         caller,
         execution,
         tail?
       ),
       do:
         dispatch_call(target, bound_arguments ++ arguments, bound_this, caller, execution, tail?)

  defp dispatch_call(
         {:function_method, "bind"},
         [bound_this | bound_arguments],
         target,
         caller,
         execution,
         false
       ) do
    run(
      %{caller | stack: [{:bound_function, target, bound_this, bound_arguments} | caller.stack]},
      execution
    )
  end

  defp dispatch_call({:function_method, "call"}, arguments, target, caller, execution, tail?) do
    {this, arguments} =
      case arguments do
        [this | rest] -> {this, rest}
        [] -> {:undefined, []}
      end

    dispatch_call(target, arguments, this, caller, execution, tail?)
  end

  defp dispatch_call(
         {:promise_method, "then"},
         arguments,
         %PromiseReference{} = promise,
         caller,
         execution,
         tail?
       ) do
    on_fulfilled = Enum.at(arguments, 0, :undefined)
    on_rejected = Enum.at(arguments, 1, :undefined)
    {result_promise, execution} = Promise.react(execution, promise, on_fulfilled, on_rejected)
    complete_call_result(result_promise, caller, execution, tail?)
  end

  defp dispatch_call(
         {:promise_method, "catch"},
         arguments,
         %PromiseReference{} = promise,
         caller,
         execution,
         tail?
       ) do
    on_rejected = Enum.at(arguments, 0, :undefined)
    {result_promise, execution} = Promise.react(execution, promise, :undefined, on_rejected)
    complete_call_result(result_promise, caller, execution, tail?)
  end

  defp dispatch_call(
         {:promise_method, "finally"},
         arguments,
         %PromiseReference{} = promise,
         caller,
         execution,
         tail?
       ) do
    callback = Enum.at(arguments, 0, :undefined)
    {result_promise, execution} = Promise.finally(execution, promise, callback)
    complete_call_result(result_promise, caller, execution, tail?)
  end

  defp dispatch_call(%Reference{} = reference, arguments, this, caller, execution, tail?) do
    case Builtins.callable(execution, reference) do
      nil ->
        raise_js_from_caller({:not_callable, reference}, caller, execution)

      callable when elem(callable, 0) in [:builtin, :builtin_method, :primitive_method] ->
        dispatch_call(callable, arguments, this, caller, execution, tail?)

      callable ->
        enter_call(callable, arguments, this, caller, execution, tail?, reference)
    end
  end

  defp dispatch_call(
         {:builtin_method, "Object", "assign"},
         arguments,
         _this,
         caller,
         execution,
         tail?
       ) do
    case arguments do
      [%Reference{} = target | sources] ->
        boundary = %ObjectAssignBoundary{
          target: target,
          sources: sources,
          caller: caller,
          depth: execution.depth,
          tail?: tail?
        }

        continue_object_assign(boundary, execution)

      _arguments ->
        raise_js_from_caller({:type_error, :not_an_object}, caller, execution)
    end
  end

  defp dispatch_call(
         {:primitive_method, :array, method},
         arguments,
         receiver,
         caller,
         execution,
         tail?
       )
       when method in ["filter", "forEach", "map", "reduce", "some"] do
    start_array_iteration(method, receiver, arguments, caller, execution, tail?)
  end

  defp dispatch_call(callable, arguments, this, caller, execution, tail?)
       when elem(callable, 0) in [:builtin, :builtin_method, :primitive_method] do
    case Builtins.call(callable, this, arguments, execution) do
      {:ok, value, execution} ->
        complete_call_result(value, caller, execution, tail?)

      {:error, reason, execution} ->
        raise_js_from_caller({:type_error, reason}, caller, execution)
    end
  end

  defp dispatch_call(callable, arguments, this, caller, execution, tail?),
    do: enter_call(callable, arguments, this, caller, execution, tail?)

  defp complete_call_result(value, %ReactionBoundary{} = boundary, execution, _tail?),
    do: complete_reaction(boundary, value, execution)

  defp complete_call_result(
         value,
         %ObjectAssignBoundary{phase: :get} = boundary,
         execution,
         _tail?
       ),
       do: assign_object_value(boundary, boundary.key, value, execution)

  defp complete_call_result(
         _value,
         %ObjectAssignBoundary{phase: :set} = boundary,
         execution,
         _tail?
       ),
       do: continue_object_assign(%{boundary | phase: nil, key: nil}, execution)

  defp complete_call_result(value, %ThenGetterBoundary{} = boundary, execution, _tail?),
    do: complete_then_getter(value, boundary, execution)

  defp complete_call_result(value, %AccessorBoundary{} = boundary, execution, _tail?),
    do: complete_accessor(value, boundary, execution)

  defp complete_call_result(value, %ConstructorBoundary{} = boundary, execution, _tail?),
    do: complete_constructor(value, boundary, execution)

  defp complete_call_result(_value, %PromiseExecutorBoundary{} = boundary, execution, _tail?),
    do: complete_executor(boundary, execution)

  defp complete_call_result(_value, %ThenableBoundary{}, execution, _tail?),
    do: {:idle, execution}

  defp complete_call_result(value, %NativeFrame{} = native, execution, _tail?),
    do: resume_native(value, native, execution)

  defp complete_call_result(value, caller, execution, tail?) do
    if tail?,
      do: return_value(value, execution),
      else: run(%{caller | stack: [value | caller.stack]}, execution)
  end

  defp complete_then_getter(value, boundary, execution) do
    execution =
      if type_of(value, execution) == "function" do
        Promise.enqueue_assimilation(execution, boundary.promise, boundary.thenable, value)
      else
        Promise.fulfill_assimilated(execution, boundary.promise, boundary.thenable)
      end

    continue_after_then_getter(boundary, execution)
  end

  defp continue_after_then_getter(%ThenGetterBoundary{continuation: %Frame{} = frame}, execution),
    do: run(frame, execution)

  defp continue_after_then_getter(%ThenGetterBoundary{continuation: nil}, execution),
    do: {:idle, execution}

  defp complete_accessor(value, %AccessorBoundary{mode: :get} = boundary, execution),
    do: run(%{boundary.caller | stack: [value | boundary.caller.stack]}, execution)

  defp complete_accessor(_value, %AccessorBoundary{mode: :set} = boundary, execution),
    do: run(boundary.caller, execution)

  defp complete_constructor(value, boundary, execution) do
    result =
      if constructor_object?(value),
        do: value,
        else: boundary.instance

    complete_call_result(result, boundary.caller, execution, false)
  end

  defp constructor_object?(value),
    do:
      is_struct(value, Reference) or is_struct(value, PromiseReference) or
        is_struct(value, RegExp) or is_map(value) or is_list(value)

  defp complete_executor(boundary, execution) do
    complete_call_result(boundary.promise, boundary.caller, execution, boundary.tail?)
  end

  defp complete_reaction(%ReactionBoundary{mode: :then} = boundary, value, execution) do
    execution = Promise.settle(execution, boundary.promise, {:ok, value})
    {:idle, execution}
  end

  defp complete_reaction(%ReactionBoundary{mode: :finally} = boundary, value, execution) do
    {completion, execution} =
      case value do
        %PromiseReference{} = promise ->
          {promise, execution}

        value ->
          {promise, execution} = Promise.new(execution)
          {promise, Promise.settle(execution, promise, {:ok, value})}
      end

    execution =
      Promise.settle_after_finally(
        execution,
        completion,
        boundary.promise,
        boundary.original_result
      )

    {:idle, execution}
  end

  defp continue_object_assign(%ObjectAssignBoundary{keys: [key | keys]} = boundary, execution) do
    case get_property(boundary.source, key, execution) do
      {:ok, {:accessor, getter, receiver}} ->
        boundary = %{boundary | phase: :get, key: key, keys: keys}
        dispatch_call(getter, [], receiver, boundary, execution, false)

      {:ok, value} ->
        assign_object_value(%{boundary | keys: keys}, key, value, execution)

      {:error, reason} ->
        raise_js_from_caller({:type_error, reason}, boundary, execution)
    end
  end

  defp continue_object_assign(
         %ObjectAssignBoundary{keys: [], sources: [source | sources]} = boundary,
         execution
       ) do
    case enumerable_keys(source, execution) do
      {:ok, keys} ->
        continue_object_assign(
          %{boundary | source: source, sources: sources, keys: keys, phase: nil, key: nil},
          execution
        )

      {:error, reason} ->
        raise_js_from_caller({:type_error, reason}, boundary, execution)
    end
  end

  defp continue_object_assign(%ObjectAssignBoundary{keys: [], sources: []} = boundary, execution),
    do: complete_call_result(boundary.target, boundary.caller, execution, boundary.tail?)

  defp assign_object_value(boundary, key, value, execution) do
    case Heap.put(execution, boundary.target, key, value) do
      {:ok, execution} ->
        continue_object_assign(%{boundary | phase: nil, key: nil}, execution)

      {:error, {:invoke_setter, setter}} ->
        boundary = %{boundary | phase: :set, key: key}
        dispatch_call(setter, [value], boundary.target, boundary, execution, false)

      {:error, reason} ->
        raise_js_from_caller({:type_error, reason}, boundary, execution)
    end
  end

  defp start_array_iteration(method, receiver, arguments, caller, execution, tail?) do
    with {:ok, value_list} <- interpreter_array_values(receiver, execution),
         [callback | rest] <- arguments do
      values = List.to_tuple(value_list)

      operation =
        case method do
          "map" -> :map
          "filter" -> :filter
          "forEach" -> :for_each
          "some" -> :some
          "reduce" -> :reduce
        end

      native = %NativeFrame{
        operation: operation,
        values: values,
        callback: callback,
        receiver: receiver,
        caller: caller,
        tail?: tail?
      }

      native =
        if operation == :reduce do
          case rest do
            [initial | _] -> %{native | accumulator: initial}
            [] when tuple_size(values) > 0 -> %{native | accumulator: elem(values, 0), index: 1}
            [] -> native
          end
        else
          native
        end

      if operation == :reduce and tuple_size(values) == 0 and rest == [] do
        raise_js_from_caller({:type_error, :reduce_of_empty_array}, caller, execution)
      else
        invoke_native_next(native, execution)
      end
    else
      {:error, reason} -> raise_js_from_caller({:type_error, reason}, caller, execution)
      [] -> raise_js_from_caller({:type_error, :missing_callback}, caller, execution)
    end
  end

  defp invoke_native_next(%NativeFrame{} = native, execution)
       when native.index >= tuple_size(native.values) do
    finish_native(native, native_result(native, execution), execution)
  end

  defp invoke_native_next(%NativeFrame{} = native, execution) do
    value = elem(native.values, native.index)

    arguments =
      if native.operation == :reduce,
        do: [native.accumulator, value, native.index, native.receiver],
        else: [value, native.index, native.receiver]

    dispatch_call(native.callback, arguments, :undefined, native, execution, false)
  end

  defp resume_native(value, %NativeFrame{} = native, execution) do
    current = elem(native.values, native.index)

    native =
      case native.operation do
        :map ->
          %{native | index: native.index + 1, results: [value | native.results]}

        :filter ->
          %{
            native
            | index: native.index + 1,
              results:
                if(Value.truthy?(value), do: [current | native.results], else: native.results)
          }

        :for_each ->
          %{native | index: native.index + 1}

        :some ->
          %{native | index: native.index + 1, accumulator: Value.truthy?(value)}

        :reduce ->
          %{native | index: native.index + 1, accumulator: value}
      end

    if native.operation == :some and native.accumulator,
      do: finish_native(native, {:value, true, execution}, execution),
      else: invoke_native_next(native, execution)
  end

  defp native_result(%NativeFrame{operation: operation, results: results}, execution)
       when operation in [:map, :filter] do
    allocate_array(Enum.reverse(results), execution)
  end

  defp native_result(%NativeFrame{operation: :for_each}, execution),
    do: {:value, :undefined, execution}

  defp native_result(%NativeFrame{operation: :some}, execution), do: {:value, false, execution}

  defp native_result(%NativeFrame{operation: :reduce, accumulator: value}, execution),
    do: {:value, value, execution}

  defp finish_native(native, {:value, value, execution}, _old_execution) do
    if native.tail?,
      do: return_value(value, execution),
      else: run(%{native.caller | stack: [value | native.caller.stack]}, execution)
  end

  defp allocate_array(values, execution) do
    {array, execution} = Heap.allocate(execution, :array)

    execution =
      values
      |> Enum.with_index()
      |> Enum.reduce(execution, fn {value, index}, execution ->
        {:ok, execution} = Heap.define(execution, array, index, value)
        execution
      end)

    {:value, array, execution}
  end

  defp interpreter_array_values(value, _execution) when is_list(value), do: {:ok, value}

  defp interpreter_array_values(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %QuickBEAM.VM.Object{kind: :array, length: length, properties: properties}} ->
        values =
          if length == 0 do
            []
          else
            for index <- 0..(length - 1) do
              case Map.get(properties, index) do
                %QuickBEAM.VM.Property{value: value} -> value
                nil -> :undefined
              end
            end
          end

        {:ok, values}

      _ ->
        {:error, :not_an_array}
    end
  end

  defp interpreter_array_values(_value, _execution), do: {:error, :not_an_array}

  defp push(frame, execution, value),
    do: continue(%{frame | stack: [value | frame.stack]}, execution)

  defp continue(frame, execution), do: run(next_frame(frame), execution)
  defp next_frame(frame), do: %{frame | pc: frame.pc + 1}

  defp unary(%Frame{stack: [value | stack]} = frame, execution, operation),
    do: continue(%{frame | stack: [operation.(value) | stack]}, execution)

  defp binary(%Frame{stack: [right, left | stack]} = frame, execution, operation),
    do: continue(%{frame | stack: [operation.(left, right) | stack]}, execution)

  defp compare(frame, execution, operation),
    do: binary(frame, execution, &Value.compare(&1, &2, operation))

  defp bitwise(frame, execution, operation),
    do: binary(frame, execution, &Value.bitwise(&1, &2, operation))

  defp detach_async(frame, execution, awaited_promise) do
    case Enum.split_while(execution.callers, &(!match?(%AsyncBoundary{}, &1))) do
      {inner_callers, [%AsyncBoundary{} = boundary | outer_callers]} ->
        coroutine = %Coroutine{
          frame: next_frame(frame),
          callers: inner_callers,
          boundary: %{boundary | caller: nil, depth: 0, mode: :detached}
        }

        execution = %{execution | callers: outer_callers, depth: boundary.depth}
        execution = Promise.await(execution, awaited_promise, coroutine)
        {:ok, deliver_async_promise(boundary, execution)}

      {_callers, []} ->
        :no_async_boundary
    end
  end

  defp await_immediate(result, frame, execution) do
    case detach_async_immediate(frame, execution, result) do
      {:ok, detached} -> detached
      :no_async_boundary -> suspend_microtask(result, frame, execution)
    end
  end

  defp detach_async_immediate(frame, execution, result) do
    case Enum.split_while(execution.callers, &(!match?(%AsyncBoundary{}, &1))) do
      {inner_callers, [%AsyncBoundary{} = boundary | outer_callers]} ->
        coroutine = %Coroutine{
          frame: next_frame(frame),
          callers: inner_callers,
          boundary: %{boundary | caller: nil, depth: 0, mode: :detached}
        }

        execution = %{execution | callers: outer_callers, depth: boundary.depth}
        execution = Promise.enqueue_coroutine(execution, coroutine, result)
        {:ok, deliver_async_promise(boundary, execution)}

      {_callers, []} ->
        :no_async_boundary
    end
  end

  defp suspend_promise_legacy(frame, execution, promise) do
    case Promise.state(execution, promise) do
      :pending ->
        {:suspended,
         %Continuation{frame: next_frame(frame), execution: execution, awaiting: promise}}

      {:fulfilled, value} ->
        suspend_microtask({:ok, value}, frame, execution)

      {:rejected, reason} ->
        suspend_microtask({:error, reason}, frame, execution)
    end
  end

  defp suspend_microtask(result, frame, execution) do
    execution = %{execution | jobs: :queue.in(result, execution.jobs)}

    continuation = %Continuation{
      frame: next_frame(frame),
      execution: execution,
      awaiting: :microtask
    }

    {:suspended, continuation}
  end

  defp install_host_globals(execution) do
    execution = Builtins.install(execution)
    {beam, execution} = Heap.allocate(execution)
    {:ok, execution} = Heap.define(execution, beam, "call", {:host_function, :beam_call})
    {global_this, execution} = Heap.allocate(execution)

    globals =
      execution.globals
      |> Map.put("Beam", beam)
      |> Map.put("globalThis", global_this)

    %{execution | globals: globals}
  end

  defp start_host_call([name | arguments], caller, execution, tail?) when is_binary(name) do
    {promise, execution} = Promise.new(execution)

    execution =
      case Map.fetch(execution.handlers, name) do
        {:ok, handler} -> start_handler_task(handler, arguments, promise, execution)
        :error -> Promise.settle(execution, promise, {:error, {:unknown_handler, name}})
      end

    if tail?,
      do: return_value(promise, execution),
      else: run(%{caller | stack: [promise | caller.stack]}, execution)
  end

  defp start_host_call(_arguments, caller, execution, _tail?),
    do: raise_js_from_caller({:type_error, :invalid_beam_call}, caller, execution)

  defp start_handler_task(handler, arguments, promise, execution) do
    operation = make_ref()
    owner = self()

    case Task.Supervisor.start_child(QuickBEAM.VM.TaskSupervisor, fn ->
           Process.link(owner)
           result = invoke_handler(handler, arguments)
           send(owner, {:quickbeam_vm_host_reply, operation, result})
         end) do
      {:ok, pid} ->
        %{execution | operations: Map.put(execution.operations, operation, {promise, pid})}

      {:error, reason} ->
        Promise.settle(execution, promise, {:error, {:handler_start_failed, reason}})
    end
  end

  defp invoke_handler(handler, arguments) do
    {:ok, handler.(arguments)}
  rescue
    exception -> {:error, {:handler_exception, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:handler_exception, {kind, reason}, __STACKTRACE__}}
  end

  defp type_of(%Reference{} = reference, execution) do
    if Builtins.callable(execution, reference), do: "function", else: "object"
  end

  defp type_of(value, _execution)
       when is_tuple(value) and
              elem(value, 0) in [
                :builtin,
                :builtin_method,
                :bound_function,
                :function_method,
                :host_function,
                :primitive_method,
                :promise_method,
                :promise_resolver
              ],
       do: "function"

  defp type_of(value, _execution), do: Value.typeof(value)

  defp get_property_and_continue(object, key, stack, frame, execution) do
    case get_property(object, key, execution) do
      {:ok, {:accessor, getter, receiver}} ->
        boundary = %AccessorBoundary{
          mode: :get,
          caller: %{next_frame(frame) | stack: stack},
          depth: execution.depth
        }

        dispatch_call(getter, [], receiver, boundary, execution, false)

      {:ok, value} ->
        continue(%{frame | stack: [value | stack]}, execution)

      {:error, reason} ->
        raise_js({:type_error, reason}, %{frame | stack: stack}, execution)
    end
  end

  defp put_property_and_continue(object, key, value, stack, frame, execution) do
    case put_property(object, key, value, execution) do
      {:ok, execution} ->
        continue(%{frame | stack: stack}, execution)

      {:error, {:invoke_setter, setter}} ->
        boundary = %AccessorBoundary{
          mode: :set,
          caller: %{next_frame(frame) | stack: stack},
          depth: execution.depth
        }

        dispatch_call(setter, [value], object, boundary, execution, false)

      {:error, reason} ->
        raise_js({:type_error, reason}, %{frame | stack: stack}, execution)
    end
  end

  defp get_property(%Reference{} = object, key, execution) do
    case Heap.get(execution, object, key) do
      {:ok, :undefined} = missing ->
        cond do
          key in ["bind", "call"] and not is_nil(Builtins.callable(execution, object)) ->
            {:ok, {:function_method, key}}

          reference_kind(object, execution) in [:array, :set] and is_binary(key) ->
            {:ok, {:primitive_method, reference_kind(object, execution), key}}

          true ->
            missing
        end

      result ->
        result
    end
  end

  defp get_property(%PromiseReference{}, method, _execution)
       when method in ["catch", "finally", "then"],
       do: {:ok, {:promise_method, method}}

  defp get_property(%RegExp{}, key, _execution) when is_binary(key),
    do: {:ok, {:primitive_method, :regexp, key}}

  defp get_property(object, key, _execution)
       when is_tuple(object) and key in ["bind", "call"] and
              elem(object, 0) in [
                :builtin,
                :builtin_method,
                :bound_function,
                :host_function,
                :primitive_method,
                :promise_method,
                :promise_resolver
              ],
       do: {:ok, {:function_method, key}}

  defp get_property(object, key, _execution) when is_map(object) and not is_struct(object) do
    case Map.fetch(object, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:ok, map_string_key(object, key)}
    end
  end

  defp get_property(object, "length", _execution) when is_binary(object),
    do: {:ok, UTF16.length(object)}

  defp get_property(object, key, _execution) when is_binary(object) and is_integer(key),
    do: {:ok, UTF16.at(object, key)}

  defp get_property(object, key, _execution) when is_binary(object) and is_binary(key),
    do: {:ok, {:primitive_method, :string, key}}

  defp get_property(object, "length", _execution) when is_list(object), do: {:ok, length(object)}

  defp get_property(object, key, _execution) when is_list(object) and is_integer(key),
    do: {:ok, Enum.at(object, key, :undefined)}

  defp get_property(object, key, _execution) when is_list(object) and is_binary(key),
    do: {:ok, {:primitive_method, :array, key}}

  defp get_property(object, key, _execution) when is_number(object) and is_binary(key),
    do: {:ok, {:primitive_method, :number, key}}

  defp get_property(object, _key, _execution) when object in [nil, :undefined],
    do: {:error, :null_or_undefined_property_access}

  defp get_property(_object, _key, _execution), do: {:ok, :undefined}

  defp put_property(%Reference{} = object, key, value, execution),
    do: Heap.put(execution, object, key, value)

  defp put_property(object, _key, _value, _execution), do: {:error, {:not_an_object, object}}

  defp enumerable_keys(%Reference{} = reference, execution),
    do: Heap.own_keys(execution, reference)

  defp enumerable_keys(value, _execution) when is_map(value), do: {:ok, Map.keys(value)}
  defp enumerable_keys([], _execution), do: {:ok, []}

  defp enumerable_keys(value, _execution) when is_list(value),
    do: {:ok, Enum.to_list(0..(length(value) - 1))}

  defp enumerable_keys(value, _execution) when value in [nil, :undefined], do: {:ok, []}
  defp enumerable_keys(_value, _execution), do: {:ok, []}

  defp has_property?(%Reference{} = reference, key, execution),
    do: Heap.has_property?(execution, reference, key)

  defp has_property?(value, key, _execution) when is_map(value), do: Map.has_key?(value, key)

  defp has_property?(value, key, _execution) when is_list(value) and is_integer(key),
    do: key >= 0 and key < length(value)

  defp has_property?(value, "length", _execution) when is_list(value) or is_binary(value),
    do: true

  defp has_property?(_value, _key, _execution), do: false

  defp reference_kind(reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %QuickBEAM.VM.Object{kind: kind}} -> kind
      :error -> nil
    end
  end

  defp map_string_key(map, key) when is_binary(key) do
    case Enum.find(map, fn
           {map_key, _value} when is_atom(map_key) -> Atom.to_string(map_key) == key
           _entry -> false
         end) do
      {_map_key, value} -> value
      nil -> :undefined
    end
  end

  defp map_string_key(_map, _key), do: :undefined

  defp raise_js(reason, %NativeFrame{caller: caller}, execution) do
    {reason, trace} = throw_state(reason)
    do_raise_js(reason, caller, execution, trace, true)
  end

  defp raise_js(reason, frame, execution) do
    {reason, trace} = throw_state(reason)
    do_raise_js(reason, frame, execution, trace, false)
  end

  defp raise_js_from_caller(reason, %ObjectAssignBoundary{} = boundary, execution) do
    {reason, trace} = throw_state(reason)
    do_raise_js(reason, boundary.caller, execution, trace, true)
  end

  defp raise_js_from_caller(reason, %ThenGetterBoundary{} = boundary, execution) do
    {reason, trace} = throw_state(reason)
    thrown = %Thrown{value: reason, frames: Enum.reverse(trace)}
    execution = Promise.settle_assimilated(execution, boundary.promise, {:error, thrown})
    continue_after_then_getter(boundary, execution)
  end

  defp raise_js_from_caller(reason, %AccessorBoundary{} = boundary, execution) do
    {reason, trace} = throw_state(reason)
    do_raise_js(reason, boundary.caller, execution, trace, true)
  end

  defp raise_js_from_caller(reason, %ConstructorBoundary{} = boundary, execution) do
    {reason, trace} = throw_state(reason)
    do_raise_js(reason, boundary.caller, execution, trace, true)
  end

  defp raise_js_from_caller(reason, %ThenableBoundary{} = boundary, execution) do
    {reason, trace} = throw_state(reason)
    thrown = %Thrown{value: reason, frames: Enum.reverse(trace)}
    execution = Promise.settle_assimilated(execution, boundary.promise, {:error, thrown})
    {:idle, execution}
  end

  defp raise_js_from_caller(reason, %PromiseExecutorBoundary{} = boundary, execution) do
    {reason, trace} = throw_state(reason)
    thrown = %Thrown{value: reason, frames: Enum.reverse(trace)}
    execution = Promise.settle(execution, boundary.promise, {:error, thrown})
    complete_executor(boundary, execution)
  end

  defp raise_js_from_caller(reason, %ReactionBoundary{} = boundary, execution) do
    {reason, trace} = throw_state(reason)
    thrown = %Thrown{value: reason, frames: Enum.reverse(trace)}
    execution = Promise.settle(execution, boundary.promise, {:error, thrown})
    {:idle, execution}
  end

  defp raise_js_from_caller(reason, %NativeFrame{caller: caller}, execution) do
    {reason, trace} = throw_state(reason)
    do_raise_js(reason, caller, execution, trace, true)
  end

  defp raise_js_from_caller(reason, frame, execution) do
    {reason, trace} = throw_state(reason)
    do_raise_js(reason, frame, execution, trace, true)
  end

  defp throw_state(%Thrown{value: value, frames: frames}),
    do: {QuickBEAM.JSError.vm_exception_value(value), Enum.reverse(frames)}

  defp throw_state(reason), do: {QuickBEAM.JSError.vm_exception_value(reason), []}

  defp do_raise_js(reason, frame, execution, trace, caller?) do
    case split_at_catch(frame.stack) do
      {:caught, target, stack_below_catch} ->
        run(%{frame | pc: target, stack: [reason | stack_below_catch]}, execution)

      :uncaught ->
        trace = [vm_stack_frame(frame, caller?) | trace]
        unwind_caller(reason, execution, trace)
    end
  end

  defp unwind_caller(reason, %Execution{callers: []} = execution, trace) do
    error = QuickBEAM.JSError.from_vm(reason, Enum.reverse(trace))
    {:error, error, execution}
  end

  defp unwind_caller(
         reason,
         %Execution{callers: [%ObjectAssignBoundary{} = boundary | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    do_raise_js(reason, boundary.caller, execution, trace, true)
  end

  defp unwind_caller(
         reason,
         %Execution{callers: [%ThenGetterBoundary{} = boundary | callers]} = execution,
         trace
       ) do
    thrown = %Thrown{value: reason, frames: Enum.reverse(trace)}
    execution = %{execution | callers: callers, depth: boundary.depth}
    execution = Promise.settle_assimilated(execution, boundary.promise, {:error, thrown})
    continue_after_then_getter(boundary, execution)
  end

  defp unwind_caller(
         reason,
         %Execution{callers: [%AccessorBoundary{} = boundary | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    do_raise_js(reason, boundary.caller, execution, trace, true)
  end

  defp unwind_caller(
         reason,
         %Execution{callers: [%ConstructorBoundary{} = boundary | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    do_raise_js(reason, boundary.caller, execution, trace, true)
  end

  defp unwind_caller(
         reason,
         %Execution{callers: [%ThenableBoundary{} = boundary | callers]} = execution,
         trace
       ) do
    thrown = %Thrown{value: reason, frames: Enum.reverse(trace)}
    execution = %{execution | callers: callers, depth: boundary.depth}
    execution = Promise.settle_assimilated(execution, boundary.promise, {:error, thrown})
    {:idle, execution}
  end

  defp unwind_caller(
         reason,
         %Execution{callers: [%PromiseExecutorBoundary{} = boundary | callers]} = execution,
         trace
       ) do
    thrown = %Thrown{value: reason, frames: Enum.reverse(trace)}
    execution = %{execution | callers: callers, depth: boundary.depth}
    execution = Promise.settle(execution, boundary.promise, {:error, thrown})
    complete_executor(boundary, execution)
  end

  defp unwind_caller(
         reason,
         %Execution{callers: [%ReactionBoundary{} = boundary | callers]} = execution,
         trace
       ) do
    thrown = %Thrown{value: reason, frames: Enum.reverse(trace)}
    execution = %{execution | callers: callers, depth: boundary.depth}
    execution = Promise.settle(execution, boundary.promise, {:error, thrown})
    {:idle, execution}
  end

  defp unwind_caller(
         reason,
         %Execution{callers: [%AsyncBoundary{} = boundary | callers]} = execution,
         trace
       ) do
    thrown = %Thrown{value: reason, frames: Enum.reverse(trace)}
    execution = %{execution | callers: callers, depth: boundary.depth}
    execution = Promise.settle(execution, boundary.promise, {:error, thrown})
    deliver_async_promise(boundary, execution)
  end

  defp unwind_caller(
         reason,
         %Execution{callers: [%NativeFrame{} = native | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: execution.depth - 1}
    do_raise_js(reason, native.caller, execution, trace, true)
  end

  defp unwind_caller(
         reason,
         %Execution{callers: [%Frame{} = caller | callers]} = execution,
         trace
       ) do
    execution = %{execution | callers: callers, depth: execution.depth - 1}
    do_raise_js(reason, caller, execution, trace, true)
  end

  defp vm_stack_frame(frame, caller?) do
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
    do: PredefinedAtoms.lookup(index) || "<anonymous>"

  defp normalize_function_name(name) when is_binary(name), do: name
  defp normalize_function_name(name), do: inspect(name)

  defp split_at_catch(stack) do
    case Enum.split_while(stack, &(!match?({:catch, _target}, &1))) do
      {_discarded, [{:catch, target} | stack]} -> {:caught, target, stack}
      {_discarded, []} -> :uncaught
    end
  end

  defp complete_async(
         value,
         %Execution{callers: [%AsyncBoundary{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    execution = Promise.settle(execution, boundary.promise, {:ok, value})
    deliver_async_promise(boundary, execution)
  end

  defp complete_async(value, execution), do: return_value(value, execution)

  defp deliver_async_promise(
         %AsyncBoundary{mode: :push, caller: caller, promise: promise},
         execution
       ),
       do: complete_call_result(promise, caller, execution, false)

  defp deliver_async_promise(%AsyncBoundary{mode: :return, promise: promise}, execution),
    do: return_value(promise, execution)

  defp deliver_async_promise(
         %AsyncBoundary{mode: :reaction, caller: boundary, promise: promise},
         execution
       ) do
    complete_reaction(boundary, promise, execution)
  end

  defp deliver_async_promise(%AsyncBoundary{mode: :executor, caller: boundary}, execution),
    do: complete_executor(boundary, execution)

  defp deliver_async_promise(%AsyncBoundary{mode: :thenable}, execution),
    do: {:idle, execution}

  defp deliver_async_promise(%AsyncBoundary{mode: :detached}, execution),
    do: {:idle, execution}

  defp return_value(value, %Execution{callers: []} = execution),
    do: {:ok, value, %{execution | depth: 0}}

  defp return_value(value, %Execution{callers: [%AsyncBoundary{} | _]} = execution),
    do: complete_async(value, execution)

  defp return_value(
         value,
         %Execution{callers: [%ObjectAssignBoundary{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    complete_call_result(value, boundary, execution, false)
  end

  defp return_value(
         value,
         %Execution{callers: [%ThenGetterBoundary{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    complete_then_getter(value, boundary, execution)
  end

  defp return_value(
         value,
         %Execution{callers: [%AccessorBoundary{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    complete_accessor(value, boundary, execution)
  end

  defp return_value(
         value,
         %Execution{callers: [%ConstructorBoundary{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    complete_constructor(value, boundary, execution)
  end

  defp return_value(
         value,
         %Execution{callers: [%ReactionBoundary{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    complete_reaction(boundary, value, execution)
  end

  defp return_value(
         _value,
         %Execution{callers: [%PromiseExecutorBoundary{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    complete_executor(boundary, execution)
  end

  defp return_value(
         _value,
         %Execution{callers: [%ThenableBoundary{} = boundary | callers]} = execution
       ) do
    {:idle, %{execution | callers: callers, depth: boundary.depth}}
  end

  defp return_value(value, %Execution{callers: [%NativeFrame{} = native | callers]} = execution) do
    execution = %{execution | callers: callers, depth: execution.depth - 1}
    resume_native(value, native, execution)
  end

  defp return_value(value, %Execution{callers: [%Frame{} = caller | callers]} = execution) do
    execution = %{execution | callers: callers, depth: execution.depth - 1}
    run(%{caller | stack: [value | caller.stack]}, execution)
  end

  defp update_local(frame, execution, index, operation) do
    value = read_slot(elem(frame.locals, index), execution)
    {locals, execution} = write_tuple_slot(frame.locals, index, operation.(value), execution)
    continue(%{frame | locals: locals}, execution)
  end

  defp allocate_function(callable, function, execution) do
    {reference, execution} = Heap.allocate(execution, :ordinary, callable: callable)

    if function.has_prototype do
      {prototype, execution} = Heap.allocate(execution)

      {:ok, execution} =
        Heap.define(execution, prototype, "constructor", reference,
          enumerable: false,
          configurable: true
        )

      {:ok, execution} =
        Heap.define(execution, reference, "prototype", prototype,
          enumerable: false,
          configurable: false
        )

      {reference, execution}
    else
      {reference, execution}
    end
  end

  defp capture_closure(%Function{closure_vars: []} = function, frame, execution),
    do: {function, frame, execution}

  defp capture_closure(%Function{} = function, frame, execution) do
    {references, frame, execution} =
      Enum.reduce(function.closure_vars, {[], frame, execution}, fn closure_var,
                                                                    {references, frame, execution} ->
        {reference, frame, execution} = capture_reference(closure_var, frame, execution)
        {[reference | references], frame, execution}
      end)

    {{:closure, function, references |> Enum.reverse() |> List.to_tuple()}, frame, execution}
  end

  defp capture_reference(%{closure_type: 0, var_idx: index}, frame, execution) do
    index = frame.function.arg_count + index
    {reference, locals, execution} = promote_tuple_slot(frame.locals, index, execution)
    {reference, %{frame | locals: locals}, execution}
  end

  defp capture_reference(%{closure_type: 1, var_idx: index}, frame, execution) do
    {reference, args, execution} = promote_tuple_slot(frame.args, index, execution)
    {reference, %{frame | args: args}, execution}
  end

  defp capture_reference(%{closure_type: 2, var_idx: index}, frame, execution),
    do: {elem(frame.closure_refs, index), frame, execution}

  defp capture_reference(%{name: name}, frame, execution),
    do: {{:global, name}, frame, execution}

  defp promote_tuple_slot(tuple, index, execution) do
    case elem(tuple, index) do
      {:cell, _id} = reference ->
        {reference, tuple, execution}

      value ->
        id = execution.next_cell_id
        reference = {:cell, id}

        execution = Memory.charge_cell(execution, value)

        execution = %{
          execution
          | cells: Map.put(execution.cells, id, value),
            next_cell_id: id + 1
        }

        {reference, put_elem(tuple, index, reference), execution}
    end
  end

  defp read_slot({:cell, _id} = reference, execution),
    do: read_reference(reference, execution)

  defp read_slot({:global, _name} = reference, execution),
    do: read_reference(reference, execution)

  defp read_slot(value, _execution), do: value

  defp read_reference({:cell, id}, execution), do: Map.fetch!(execution.cells, id)

  defp read_reference({:global, name}, execution),
    do: Map.get(execution.globals, name, :undefined)

  defp write_reference({:cell, id}, value, execution),
    do: %{execution | cells: Map.put(execution.cells, id, value)}

  defp write_reference({:global, name}, value, execution),
    do: %{execution | globals: Map.put(execution.globals, name, value)}

  defp write_tuple_slot(tuple, index, value, execution) do
    case elem(tuple, index) do
      {:cell, _id} = reference -> {tuple, write_reference(reference, value, execution)}
      {:global, _name} = reference -> {tuple, write_reference(reference, value, execution)}
      _value -> {put_elem(tuple, index, value), execution}
    end
  end

  defp tuple_get(tuple, index) when index < tuple_size(tuple), do: elem(tuple, index)
  defp tuple_get(_tuple, _index), do: :undefined

  defp resolve_atom(:empty_string, _execution), do: ""
  defp resolve_atom({:tagged_int, value}, _execution), do: value

  defp resolve_atom({:predefined, index}, _execution),
    do: PredefinedAtoms.lookup(index) || {:predefined, index}

  defp resolve_atom(index, execution) when is_integer(index) and index >= 0 do
    if index < tuple_size(execution.atoms),
      do: elem(execution.atoms, index),
      else: {:atom, index}
  end

  defp resolve_atom(value, _execution), do: value
end
