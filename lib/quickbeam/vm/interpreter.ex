defmodule QuickBEAM.VM.Interpreter do
  @moduledoc """
  Executes verified QuickJS bytecode with explicit JavaScript machine state.

  Frames, callers, exception unwinding, async boundaries, and native callback
  frames are represented as data so execution can suspend without retaining an
  Elixir or native call stack.
  """

  alias QuickBEAM.VM.{
    AccessorBoundary,
    Async,
    AsyncBoundary,
    Builtins,
    Continuation,
    ConstructorBoundary,
    Coroutine,
    Execution,
    Exceptions,
    Export,
    Frame,
    Function,
    Heap,
    Invocation,
    Memory,
    NativeFrame,
    ObjectAssignBoundary,
    Opcodes,
    PredefinedAtoms,
    Program,
    Properties,
    PromiseExecutorBoundary,
    PromiseReference,
    Reaction,
    ReactionBoundary,
    Reference,
    RegExp,
    ThenableBoundary,
    ThenGetterBoundary,
    Value
  }

  alias QuickBEAM.VM.Opcodes.Stack, as: StackOpcodes
  alias QuickBEAM.VM.Opcodes.Values, as: ValueOpcodes

  @default_max_steps 5_000_000
  @default_max_stack_depth 1_000

  @stack_opcodes StackOpcodes.opcodes()
  @value_opcodes ValueOpcodes.opcodes()

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
    frame = Invocation.new_frame(program.root, program.root, [], :undefined, {})
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
  def resume_coroutine(%Coroutine{} = coroutine, result, %Execution{} = execution),
    do: coroutine |> Async.resume_coroutine(result, execution) |> execute_async()

  @doc "Reads a thenable's accessor-backed `then` property during Promise resolution."
  def read_thenable(promise, thenable, getter, %Execution{} = execution),
    do: promise |> Async.read_thenable(thenable, getter, nil, execution) |> execute_async()

  @doc "Runs one pending synchronous Promise-resolution job, when present."
  def run_synchronous_job(%Execution{} = execution) do
    case :queue.out(execution.sync_jobs) do
      {{:value, {:read_thenable, promise, thenable, getter}}, sync_jobs} ->
        execution = %{execution | sync_jobs: sync_jobs}
        promise |> Async.read_thenable(thenable, getter, nil, execution) |> execute_async()

      {:empty, _sync_jobs} ->
        {:none, execution}
    end
  end

  @doc "Invokes a thenable and connects its resolver functions to a Promise."
  def assimilate_thenable(promise, thenable, callable, %Execution{} = execution),
    do: promise |> Async.assimilate_thenable(thenable, callable, execution) |> execute_async()

  @doc "Runs one queued Promise reaction against a source settlement."
  def run_reaction(%Reaction{} = reaction, result, %Execution{} = execution),
    do: reaction |> Async.run_reaction(result, execution) |> execute_async()

  @doc "Converts a raw machine result into the interpreter's public result."
  def finish({:ok, value, execution}), do: Export.value(value, execution)
  def finish({:error, reason, _execution}), do: {:error, reason}
  def finish({:suspended, continuation}), do: {:suspended, continuation}
  def finish({:idle, _execution}), do: {:error, :idle_evaluation}

  defp enter_planned_call(
         function,
         callable,
         closure_refs,
         arguments,
         this,
         caller,
         execution,
         tail?
       ) do
    if function.func_kind == 2 do
      enter_async_call(
        function,
        callable,
        closure_refs,
        arguments,
        this,
        caller,
        execution,
        tail?
      )
    else
      enter_sync_call(
        function,
        callable,
        closure_refs,
        arguments,
        this,
        caller,
        execution,
        tail?
      )
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

      run(Invocation.new_frame(function, callable, args, this, closure_refs), execution)
    end
  end

  defp enter_async_call(function, callable, closure_refs, args, this, caller, execution, tail?) do
    function
    |> Async.enter(callable, closure_refs, args, this, caller, execution, tail?)
    |> execute_async()
  end

  defp execute_async({:run, frame, execution}), do: run(frame, execution)

  defp execute_async({:raise, reason, frame, execution}),
    do: raise_js_from_caller(reason, frame, execution)

  defp execute_async({:invoke, callable, arguments, this, caller, execution, tail?}),
    do: dispatch_call(callable, arguments, this, caller, execution, tail?)

  defp execute_async({:complete, value, caller, execution, tail?}),
    do: complete_call_result(value, caller, execution, tail?)

  defp execute_async({:return, value, execution}), do: return_value(value, execution)
  defp execute_async({:idle, execution}), do: {:idle, execution}
  defp execute_async({:suspended, continuation}), do: {:suspended, continuation}
  defp execute_async({:error, reason, execution}), do: {:error, reason, execution}

  defp run(frame, %Execution{} = execution) when execution.sync_jobs != {[], []} do
    case :queue.out(execution.sync_jobs) do
      {{:value, {:read_thenable, promise, thenable, getter}}, sync_jobs} ->
        execution = %{execution | sync_jobs: sync_jobs}
        promise |> Async.read_thenable(thenable, getter, frame, execution) |> execute_async()

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

  defp execute(name, operands, frame, execution) when name in @stack_opcodes,
    do: name |> StackOpcodes.execute(operands, frame, execution) |> execute_opcode()

  defp execute(name, operands, frame, execution) when name in @value_opcodes,
    do: name |> ValueOpcodes.execute(operands, frame, execution) |> execute_opcode()

  defp execute(:push_atom_value, [atom], frame, execution),
    do: push(frame, execution, resolve_atom(atom, execution))

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
        {:ok, execution} =
          Properties.define(arguments, index, read_slot(value, execution), execution)

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
        {:ok, execution} = Properties.define(reference, index, value, execution)
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
        4 -> Properties.define(object, key, callable, execution)
        5 -> Properties.define_accessor(object, key, :getter, callable, execution)
        6 -> Properties.define_accessor(object, key, :setter, callable, execution)
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

    case Properties.define(object, key, value, execution) do
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
    case Properties.delete(object, key, execution) do
      {:ok, deleted?, execution} -> continue(%{frame | stack: [deleted? | stack]}, execution)
      {:error, reason} -> raise_js({:type_error, reason}, frame, execution)
    end
  end

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
    do: update_local(frame, execution, index, &Value.unary(:inc, &1))

  defp execute(:dec_loc, [index], frame, execution),
    do: update_local(frame, execution, index, &Value.unary(:dec, &1))

  defp execute(:add_loc, [index], %{stack: [value | stack]} = frame, execution) do
    current = read_slot(elem(frame.locals, index), execution)

    {locals, execution} =
      write_tuple_slot(frame.locals, index, Value.binary(:add, current, value), execution)

    continue(%{frame | locals: locals, stack: stack}, execution)
  end

  defp execute(:for_in_start, [], %{stack: [object | stack]} = frame, execution) do
    case Properties.enumerable_keys(object, execution) do
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
        if Invocation.constructable?(constructor, execution) do
          caller = %{next_frame(frame) | stack: rest}
          prototype = Invocation.constructor_prototype(constructor, execution)

          {instance, execution} =
            Heap.allocate(execution, :ordinary,
              prototype: prototype,
              internal: :constructor_instance
            )

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

  defp dispatch_call(callable, arguments, this, caller, execution, tail?) do
    callable
    |> Invocation.plan(arguments, this, caller, execution, tail?)
    |> execute_invocation()
  end

  defp execute_invocation({:dispatch, callable, arguments, this, caller, execution, tail?}),
    do: dispatch_call(callable, arguments, this, caller, execution, tail?)

  defp execute_invocation(
         {:enter, function, callable, closure_refs, arguments, this, caller, execution, tail?}
       ),
       do:
         enter_planned_call(
           function,
           callable,
           closure_refs,
           arguments,
           this,
           caller,
           execution,
           tail?
         )

  defp execute_invocation({:complete, value, caller, execution, tail?}),
    do: complete_call_result(value, caller, execution, tail?)

  defp execute_invocation({:error, reason, caller, execution}),
    do: raise_js_from_caller(reason, caller, execution)

  defp execute_invocation({:host_call, arguments, caller, execution, tail?}),
    do: start_host_call(arguments, caller, execution, tail?)

  defp execute_invocation({:object_assign, target, sources, caller, execution, tail?}) do
    boundary = %ObjectAssignBoundary{
      target: target,
      sources: sources,
      caller: caller,
      depth: execution.depth,
      tail?: tail?
    }

    continue_object_assign(boundary, execution)
  end

  defp execute_invocation(
         {:array_iteration, method, receiver, arguments, caller, execution, tail?}
       ),
       do: start_array_iteration(method, receiver, arguments, caller, execution, tail?)

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

  defp complete_then_getter(value, boundary, execution),
    do: value |> Async.complete_then_getter(boundary, execution) |> execute_async()

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

  defp complete_reaction(boundary, value, execution),
    do: boundary |> Async.complete_reaction(value, execution) |> execute_async()

  defp continue_object_assign(%ObjectAssignBoundary{keys: [key | keys]} = boundary, execution) do
    case Properties.get(boundary.source, key, execution) do
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
    case Properties.enumerable_keys(source, execution) do
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
    case Properties.put(boundary.target, key, value, execution) do
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
        {:ok, execution} = Properties.define(array, index, value, execution)
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

  defp execute_opcode({:next, frame, execution}), do: continue(frame, execution)

  defp execute_opcode({:throw, reason, frame, execution}),
    do: raise_js(reason, frame, execution)

  defp detach_async(frame, execution, awaited_promise) do
    case Async.detach_await(next_frame(frame), execution, awaited_promise) do
      {:ok, action} -> {:ok, execute_async(action)}
      :no_async_boundary -> :no_async_boundary
    end
  end

  defp await_immediate(result, frame, execution) do
    case detach_async_immediate(frame, execution, result) do
      {:ok, detached} -> detached
      :no_async_boundary -> suspend_microtask(result, frame, execution)
    end
  end

  defp detach_async_immediate(frame, execution, result) do
    case Async.detach_immediate(next_frame(frame), execution, result) do
      {:ok, action} -> {:ok, execute_async(action)}
      :no_async_boundary -> :no_async_boundary
    end
  end

  defp suspend_promise_legacy(frame, execution, promise),
    do: frame |> next_frame() |> Async.suspend_promise(execution, promise) |> execute_async()

  defp suspend_microtask(result, frame, execution),
    do: frame |> next_frame() |> Async.suspend_microtask(execution, result) |> execute_async()

  defp install_host_globals(execution) do
    execution = Builtins.install(execution)
    {beam, execution} = Heap.allocate(execution)

    {:ok, execution} =
      Properties.define(beam, "call", {:host_function, :beam_call}, execution)

    {global_this, execution} = Heap.allocate(execution)

    globals =
      execution.globals
      |> Map.put_new("Infinity", :infinity)
      |> Map.put_new("NaN", :nan)
      |> Map.put_new("undefined", :undefined)
      |> Map.put("Beam", beam)
      |> Map.put("globalThis", global_this)

    %{execution | globals: globals}
  end

  defp start_host_call(arguments, caller, execution, tail?) do
    case Async.start_host_call(arguments, execution) do
      {:ok, promise, execution} -> complete_call_result(promise, caller, execution, tail?)
      {:error, reason, execution} -> raise_js_from_caller(reason, caller, execution)
    end
  end

  defp get_property_and_continue(object, key, stack, frame, execution) do
    case Properties.get(object, key, execution) do
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
    case Properties.put(object, key, value, execution) do
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

  defp raise_js(reason, frame, execution),
    do: reason |> Exceptions.throw_at(frame, execution) |> execute_exception()

  defp raise_js_from_caller(reason, caller, execution),
    do: reason |> Exceptions.throw_from(caller, execution) |> execute_exception()

  defp execute_exception({:run, frame, execution}), do: run(frame, execution)

  defp execute_exception({:resume_then_getter, boundary, execution}),
    do: continue_after_then_getter(boundary, execution)

  defp execute_exception({:complete, value, caller, execution, tail?}),
    do: complete_call_result(value, caller, execution, tail?)

  defp execute_exception({:async, action}), do: execute_async(action)
  defp execute_exception({:idle, execution}), do: {:idle, execution}
  defp execute_exception({:error, error, execution}), do: {:error, error, execution}

  defp complete_async(
         value,
         %Execution{callers: [%AsyncBoundary{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    boundary |> Async.complete({:ok, value}, execution) |> execute_async()
  end

  defp complete_async(value, execution), do: return_value(value, execution)

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
    {reference, execution} = Heap.allocate(execution, :function, callable: callable)

    if function.has_prototype do
      {prototype, execution} = Heap.allocate(execution)

      {:ok, execution} =
        Properties.define(prototype, "constructor", reference, execution,
          enumerable: false,
          configurable: true
        )

      {:ok, execution} =
        Properties.define(reference, "prototype", prototype, execution,
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
