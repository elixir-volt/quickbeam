defmodule QuickBEAM.VM.Runtime.Interpreter do
  @moduledoc """
  Executes verified QuickJS bytecode with explicit JavaScript machine state.

  Frames, callers, exception unwinding, async boundaries, and native callback
  frames are represented as data so execution can suspend without retaining an
  Elixir or native call stack.
  """

  alias QuickBEAM.VM.Runtime.Boundary
  alias QuickBEAM.VM.Runtime.Async

  alias QuickBEAM.VM.Builtin.Runtime, as: BuiltinRuntime
  alias QuickBEAM.VM.Builtin.Set, as: SetBuiltin

  alias QuickBEAM.VM.Runtime.Continuation
  alias QuickBEAM.VM.Runtime.Coroutine
  alias QuickBEAM.VM.Runtime.Exception
  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Value.Export
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Invocation
  alias QuickBEAM.VM.Runtime.Iterator

  alias QuickBEAM.VM.Runtime.Memory
  alias QuickBEAM.VM.Runtime.Frame.Native

  alias QuickBEAM.VM.Bytecode.Opcode
  alias QuickBEAM.VM.Program
  alias QuickBEAM.VM.Runtime.Promise

  alias QuickBEAM.VM.Runtime.Promise.Reference, as: PromiseReference
  alias QuickBEAM.VM.Runtime.Property
  alias QuickBEAM.VM.Runtime.Promise.Reaction

  alias QuickBEAM.VM.Runtime.Reference
  alias QuickBEAM.VM.Runtime.RegExp

  alias QuickBEAM.VM.Runtime.Value

  alias QuickBEAM.VM.Builtin.Registry
  alias QuickBEAM.VM.Runtime.Optimization
  alias QuickBEAM.VM.Runtime.Opcode.Control, as: ControlOpcodes
  alias QuickBEAM.VM.Runtime.Opcode.Invocation, as: InvocationOpcodes
  alias QuickBEAM.VM.Runtime.Opcode.Local, as: LocalOpcodes
  alias QuickBEAM.VM.Runtime.Opcode.Object, as: ObjectOpcodes
  alias QuickBEAM.VM.Runtime.Opcode.Stack, as: StackOpcodes
  alias QuickBEAM.VM.Runtime.Opcode.Value, as: ValueOpcodes

  @default_max_steps 5_000_000
  @default_max_stack_depth 1_000
  @host_template_cache {__MODULE__, :host_templates}
  @host_override_names ["Beam", "globalThis"]
  @host_user_names ["Infinity", "NaN", "undefined"]

  @control_opcodes ControlOpcodes.opcodes()
  @invocation_opcodes InvocationOpcodes.opcodes()
  @local_opcodes LocalOpcodes.opcodes()
  @object_opcodes ObjectOpcodes.opcodes()
  @stack_opcodes StackOpcodes.opcodes()
  @value_opcodes ValueOpcodes.opcodes()

  @type result ::
          {:ok, term()}
          | {:error, term()}
          | {:suspended, Continuation.t()}

  @doc "Evaluates a verified program and exports its final result."
  @spec eval(Program.t(), keyword()) :: result()
  def eval(%Program{} = program, opts \\ []), do: program |> start(opts) |> finish()

  @doc "Initializes the canonical owner-local frame and execution state."
  @spec initialize(Program.t(), keyword()) :: {Frame.t(), State.t()}
  def initialize(%Program{} = program, opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    vars = Map.new(Keyword.get(opts, :vars, %{}))

    execution = %State{
      atoms: program.atoms,
      globals: vars,
      handlers: Map.new(Keyword.get(opts, :handlers, %{})),
      max_stack_depth: Keyword.get(opts, :max_stack_depth, @default_max_stack_depth),
      memory_limit: Keyword.get(opts, :memory_limit, :infinity),
      measurement_target: Keyword.get(opts, :measurement_target),
      remaining_steps: max_steps,
      step_limit: max_steps
    }

    execution = Memory.charge(execution, Memory.estimate(vars))
    execution = install_host_globals(execution, Keyword.get(opts, :profile, :core))
    frame = Invocation.new_frame(program.root, program.root, [], :undefined, {})
    {frame, execution}
  end

  @doc "Starts interpreting a program and returns its raw machine result."
  def start(%Program{} = program, opts \\ []) do
    {frame, execution} = initialize(program, opts)
    run(frame, execution)
  end

  @doc "Runs one canonical frame and execution state through the machine loop."
  @spec run_frame(Frame.t(), State.t()) :: term()
  def run_frame(%Frame{} = frame, %State{} = execution), do: run(frame, execution)

  @doc "Resumes an explicit generated-code invocation through canonical dispatch."
  @spec resume_compiler_invoke(term(), [term()], term(), Frame.t(), State.t()) :: term()
  def resume_compiler_invoke(
        callable,
        arguments,
        this,
        %Frame{} = caller,
        %State{} = execution
      ),
      do: dispatch_call(callable, arguments, this, caller, execution, false)

  @doc "Resumes a suspended continuation and exports its final result."
  @spec resume(Continuation.t(), {:ok, term()} | {:error, term()}) :: result()
  def resume(%Continuation{} = continuation, result),
    do: continuation |> resume_raw(result) |> finish()

  @doc "Resumes a validated owner-local compiler deoptimization."
  @spec resume_deopt(struct()) :: result()
  def resume_deopt(%{frame: %Frame{}, execution: %State{}} = deopt),
    do: deopt |> resume_deopt_raw() |> finish()

  @doc "Resumes compiler deoptimization without exporting the resulting value."
  @spec resume_deopt_raw(struct()) ::
          {:ok, term(), State.t()} | {:error, term(), State.t()} | {:suspended, term()}
  def resume_deopt_raw(%{frame: %Frame{}, execution: %State{}} = deopt) do
    case Optimization.validate_deopt(deopt) do
      :ok ->
        frame =
          if deopt.frame.compiler_allow_reentry,
            do: %{deopt.frame | compiler_reentry_after_instruction: true},
            else: deopt.frame

        run(frame, deopt.execution)

      {:error, reason} ->
        {:error, {:invalid_compiler_deopt, reason}, deopt.execution}
    end
  end

  @doc "Resumes a legacy continuation without exporting the resulting value."
  def resume_raw(%Continuation{} = continuation, {:ok, value}) do
    frame = %{continuation.frame | stack: [value | continuation.frame.stack]}
    run(frame, continuation.execution)
  end

  def resume_raw(%Continuation{} = continuation, {:error, reason}) do
    raise_js_from_caller(reason, continuation.frame, continuation.execution)
  end

  @doc "Resumes a detached async coroutine with a Promise settlement."
  def resume_coroutine(%Coroutine{} = coroutine, result, %State{} = execution),
    do: coroutine |> Async.resume_coroutine(result, execution) |> execute_async()

  @doc "Reads a thenable's accessor-backed `then` property during Promise resolution."
  def read_thenable(promise, thenable, getter, %State{} = execution),
    do: promise |> Async.read_thenable(thenable, getter, nil, execution) |> execute_async()

  @doc "Runs one pending synchronous Promise-resolution job, when present."
  def run_synchronous_job(%State{} = execution) do
    case :queue.out(execution.sync_jobs) do
      {{:value, {:read_thenable, promise, thenable, getter}}, sync_jobs} ->
        execution = %{execution | sync_jobs: sync_jobs}
        promise |> Async.read_thenable(thenable, getter, nil, execution) |> execute_async()

      {:empty, _sync_jobs} ->
        {:none, execution}
    end
  end

  @doc "Invokes a thenable and connects its resolver functions to a Promise."
  def assimilate_thenable(promise, thenable, callable, %State{} = execution),
    do: promise |> Async.assimilate_thenable(thenable, callable, execution) |> execute_async()

  @doc "Runs one queued Promise reaction against a source settlement."
  def run_reaction(%Reaction{} = reaction, result, %State{} = execution),
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

  defp execute_async({:continue_iterator, boundary, execution}),
    do: continue_iterator_sync(boundary, execution)

  defp execute_async({:idle, execution}), do: {:idle, execution}
  defp execute_async({:suspended, continuation}), do: {:suspended, continuation}
  defp execute_async({:error, reason, execution}), do: {:error, reason, execution}

  defp run(frame, %State{} = execution) when execution.sync_jobs != {[], []} do
    case :queue.out(execution.sync_jobs) do
      {{:value, {:read_thenable, promise, thenable, getter}}, sync_jobs} ->
        execution = %{execution | sync_jobs: sync_jobs}
        promise |> Async.read_thenable(thenable, getter, frame, execution) |> execute_async()

      {:empty, _sync_jobs} ->
        run(frame, %{execution | sync_jobs: {[], []}})
    end
  end

  defp run(_frame, %State{memory_exceeded: true} = execution),
    do: {:error, {:limit_exceeded, :memory_bytes, execution.memory_limit}, execution}

  defp run(_frame, %State{remaining_steps: 0} = execution),
    do: {:error, {:limit_exceeded, :steps, execution.step_limit}, execution}

  defp run(%Frame{pc: pc, function: function}, execution)
       when pc >= tuple_size(function.instructions),
       do: {:error, {:invalid_program_counter, pc}, execution}

  defp run(
         %Frame{compiler_reentry_after_instruction: true} = frame,
         %State{} = execution
       ) do
    frame = %{frame | compiler_entered: false, compiler_reentry_after_instruction: false}
    execution = Optimization.increment(execution, :reentries)
    execute_current(frame, execution)
  end

  defp run(
         %Frame{compiler_entered: false} = frame,
         %State{compiler_context: compiler_context} = execution
       )
       when not is_nil(compiler_context) do
    frame = %{frame | compiler_entered: true}

    case Optimization.execute_frame(frame, execution) do
      {:deopt, deopt} = action ->
        if Optimization.deopt?(deopt, execution),
          do: resume_deopt_raw(deopt),
          else: {:error, {:compiler_error, {:invalid_generated_action, action}}, execution}

      {:invoke, callable, arguments, this, caller, execution, false} ->
        dispatch_call(callable, arguments, this, caller, execution, false)

      {:skip, frame, execution} ->
        run(frame, execution)

      {:error, reason} ->
        {:error, {:compiler_error, reason}, execution}

      action ->
        {:error, {:compiler_error, {:invalid_generated_action, action}}, execution}
    end
  end

  defp run(%Frame{} = frame, %State{} = execution), do: execute_current(frame, execution)

  defp execute_current(frame, %State{compiler_context: context} = execution)
       when not is_nil(context) do
    {opcode, operands} = elem(frame.function.instructions, frame.pc)

    execution =
      execution
      |> Optimization.observe(frame)
      |> Optimization.interpreted_opcode(opcode)

    execute_current_opcode(opcode, operands, frame, execution)
  end

  defp execute_current(frame, execution) do
    {opcode, operands} = elem(frame.function.instructions, frame.pc)
    execute_current_opcode(opcode, operands, frame, execution)
  end

  defp execute_current_opcode(opcode, operands, frame, execution) do
    {name, _size, _pops, _pushes, _format} = Opcode.info(opcode)
    {name, operands} = Opcode.expand_short_form(name, operands, frame.function.arg_count)
    execution = %{execution | remaining_steps: execution.remaining_steps - 1}
    execute(name, operands, frame, execution)
  end

  defp execute(name, operands, frame, execution) when name in @control_opcodes,
    do: name |> ControlOpcodes.execute(operands, frame, execution) |> execute_opcode()

  defp execute(name, operands, frame, execution) when name in @invocation_opcodes,
    do: name |> InvocationOpcodes.execute(operands, frame, execution) |> execute_opcode()

  defp execute(name, operands, frame, execution) when name in @local_opcodes,
    do: name |> LocalOpcodes.execute(operands, frame, execution) |> execute_opcode()

  defp execute(name, operands, frame, execution) when name in @object_opcodes,
    do: name |> ObjectOpcodes.execute(operands, frame, execution) |> execute_opcode()

  defp execute(name, operands, frame, execution) when name in @stack_opcodes,
    do: name |> StackOpcodes.execute(operands, frame, execution) |> execute_opcode()

  defp execute(name, operands, frame, execution) when name in @value_opcodes,
    do: name |> ValueOpcodes.execute(operands, frame, execution) |> execute_opcode()

  defp execute(name, _operands, frame, execution)
       when name in [:nop, :set_name, :set_name_computed],
       do: continue(frame, execution)

  defp execute(name, operands, _frame, execution),
    do: {:error, {:unsupported_opcode, name, operands}, execution}

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
    boundary = %Boundary.ObjectAssign{
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

  defp execute_invocation({:promise_iterate, kind, iterable, caller, execution, tail?}),
    do: kind |> Iterator.start(iterable, caller, execution, tail?) |> execute_invocation()

  defp execute_invocation({:set_iterate, target, iterable, caller, execution, tail?}),
    do: target |> Iterator.start_set(iterable, caller, execution, tail?) |> execute_invocation()

  defp execute_invocation({:initialize_set, target, values, caller, execution, tail?}) do
    case SetBuiltin.initialize(target, values, execution) do
      {:ok, execution} ->
        execute_invocation({:complete, target, caller, execution, tail?})

      {:error, reason} ->
        execute_invocation({:error, reason, caller, execution})
    end
  end

  defp execute_invocation(
         {:iterator_value, value, %Boundary.Iterator{consumer: :promise} = boundary, execution}
       ) do
    {source, execution} = Promise.from_value(execution, value)
    boundary = %{boundary | values: [source | boundary.values]}
    continue_iterator_sync(boundary, execution)
  end

  defp execute_invocation(
         {:iterator_value, value, %Boundary.Iterator{consumer: :set} = boundary, execution}
       ) do
    boundary = %{boundary | values: [value | boundary.values]}
    boundary |> Iterator.continue(execution) |> execute_invocation()
  end

  defp complete_call_result(value, %Boundary.Iterator{} = boundary, execution, _tail?),
    do: value |> Iterator.resume(boundary, execution) |> execute_invocation()

  defp complete_call_result(value, %Boundary.Reaction{} = boundary, execution, _tail?),
    do: complete_reaction(boundary, value, execution)

  defp complete_call_result(
         value,
         %Boundary.ObjectAssign{phase: :get} = boundary,
         execution,
         _tail?
       ),
       do: assign_object_value(boundary, boundary.key, value, execution)

  defp complete_call_result(
         _value,
         %Boundary.ObjectAssign{phase: :set} = boundary,
         execution,
         _tail?
       ),
       do: continue_object_assign(%{boundary | phase: nil, key: nil}, execution)

  defp complete_call_result(value, %Boundary.ThenGetter{} = boundary, execution, _tail?),
    do: complete_then_getter(value, boundary, execution)

  defp complete_call_result(value, %Boundary.Accessor{} = boundary, execution, _tail?),
    do: complete_accessor(value, boundary, execution)

  defp complete_call_result(value, %Boundary.Constructor{} = boundary, execution, _tail?),
    do: complete_constructor(value, boundary, execution)

  defp complete_call_result(_value, %Boundary.PromiseExecutor{} = boundary, execution, _tail?),
    do: complete_executor(boundary, execution)

  defp complete_call_result(_value, %Boundary.Thenable{}, execution, _tail?),
    do: {:idle, execution}

  defp complete_call_result(value, %Native{} = native, execution, _tail?),
    do: resume_native(value, native, execution)

  defp complete_call_result(value, caller, execution, tail?) do
    if tail?,
      do: return_value(value, execution),
      else: run(%{caller | stack: [value | caller.stack]}, execution)
  end

  defp complete_then_getter(value, boundary, execution),
    do: value |> Async.complete_then_getter(boundary, execution) |> execute_async()

  defp continue_after_then_getter(
         %Boundary.ThenGetter{continuation: %Frame{} = frame},
         execution
       ),
       do: run(frame, execution)

  defp continue_after_then_getter(
         %Boundary.ThenGetter{continuation: %Boundary.Iterator{} = boundary},
         execution
       ),
       do: continue_iterator_sync(boundary, execution)

  defp continue_after_then_getter(%Boundary.ThenGetter{continuation: nil}, execution),
    do: {:idle, execution}

  defp continue_iterator_sync(boundary, execution) do
    case :queue.out(execution.sync_jobs) do
      {{:value, {:read_thenable, promise, thenable, getter}}, sync_jobs} ->
        execution = %{execution | sync_jobs: sync_jobs}

        promise
        |> Async.read_thenable(thenable, getter, boundary, execution)
        |> execute_async()

      {:empty, _sync_jobs} ->
        boundary |> Iterator.continue(%{execution | sync_jobs: {[], []}}) |> execute_invocation()
    end
  end

  defp complete_accessor(value, %Boundary.Accessor{mode: :get} = boundary, execution),
    do: run(%{boundary.caller | stack: [value | boundary.caller.stack]}, execution)

  defp complete_accessor(_value, %Boundary.Accessor{mode: :set} = boundary, execution),
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

  defp continue_object_assign(%Boundary.ObjectAssign{keys: [key | keys]} = boundary, execution) do
    case Property.get(boundary.source, key, execution) do
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
         %Boundary.ObjectAssign{keys: [], sources: [source | sources]} = boundary,
         execution
       ) do
    case Property.assignable_keys(source, execution) do
      {:ok, keys} ->
        continue_object_assign(
          %{boundary | source: source, sources: sources, keys: keys, phase: nil, key: nil},
          execution
        )

      {:error, reason} ->
        raise_js_from_caller({:type_error, reason}, boundary, execution)
    end
  end

  defp continue_object_assign(
         %Boundary.ObjectAssign{keys: [], sources: []} = boundary,
         execution
       ),
       do: complete_call_result(boundary.target, boundary.caller, execution, boundary.tail?)

  defp assign_object_value(boundary, key, value, execution) do
    case Property.put(boundary.target, key, value, execution) do
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

      native = %Native{
        operation: operation,
        values: values,
        callback: callback,
        receiver: receiver,
        caller: caller,
        tail?: tail?
      }

      case initialize_native(native, rest) do
        {:ok, native} ->
          invoke_native_next(native, execution)

        {:error, :reduce_of_empty_array} ->
          raise_js_from_caller({:type_error, :reduce_of_empty_array}, caller, execution)
      end
    else
      {:error, reason} -> raise_js_from_caller({:type_error, reason}, caller, execution)
      [] -> raise_js_from_caller({:type_error, :missing_callback}, caller, execution)
    end
  end

  defp initialize_native(%Native{operation: :reduce} = native, [initial | _]),
    do: {:ok, %{native | accumulator: initial}}

  defp initialize_native(%Native{operation: :reduce} = native, []) do
    case next_present(native.values, 0) do
      {:ok, index, value} -> {:ok, %{native | accumulator: value, index: index + 1}}
      :none -> {:error, :reduce_of_empty_array}
    end
  end

  defp initialize_native(%Native{} = native, _arguments), do: {:ok, native}

  defp next_present(values, index) when index >= tuple_size(values), do: :none

  defp next_present(values, index) do
    case elem(values, index) do
      :hole -> next_present(values, index + 1)
      {:present, value} -> {:ok, index, value}
    end
  end

  defp invoke_native_next(%Native{} = native, execution)
       when native.index >= tuple_size(native.values) do
    finish_native(native, native_result(native, execution), execution)
  end

  defp invoke_native_next(%Native{} = native, execution) do
    case elem(native.values, native.index) do
      :hole ->
        results = if native.operation == :map, do: [:hole | native.results], else: native.results
        invoke_native_next(%{native | index: native.index + 1, results: results}, execution)

      {:present, value} ->
        arguments =
          if native.operation == :reduce,
            do: [native.accumulator, value, native.index, native.receiver],
            else: [value, native.index, native.receiver]

        dispatch_call(native.callback, arguments, :undefined, native, execution, false)
    end
  end

  defp resume_native(value, %Native{} = native, execution) do
    {:present, current} = elem(native.values, native.index)

    native =
      case native.operation do
        :map ->
          %{native | index: native.index + 1, results: [{:present, value} | native.results]}

        :filter ->
          %{
            native
            | index: native.index + 1,
              results:
                if(
                  Value.truthy?(value),
                  do: [{:present, current} | native.results],
                  else: native.results
                )
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

  defp native_result(%Native{operation: operation, results: results}, execution)
       when operation in [:map, :filter] do
    allocate_array(Enum.reverse(results), execution)
  end

  defp native_result(%Native{operation: :for_each}, execution),
    do: {:value, :undefined, execution}

  defp native_result(%Native{operation: :some}, execution), do: {:value, false, execution}

  defp native_result(%Native{operation: :reduce, accumulator: value}, execution),
    do: {:value, value, execution}

  defp finish_native(native, {:value, value, execution}, _old_execution) do
    if native.tail?,
      do: return_value(value, execution),
      else: run(%{native.caller | stack: [value | native.caller.stack]}, execution)
  end

  defp allocate_array(entries, execution) do
    {array, execution} = Heap.allocate(execution, :array)

    execution =
      entries
      |> Enum.with_index()
      |> Enum.reduce(execution, fn
        {{:present, value}, index}, execution ->
          {:ok, execution} = Property.define(array, index, value, execution)
          execution

        {:hole, _index}, execution ->
          execution
      end)

    {:ok, execution} = Property.define(array, "length", length(entries), execution)
    {:value, array, execution}
  end

  defp interpreter_array_values(value, _execution) when is_list(value),
    do: {:ok, Enum.map(value, &{:present, &1})}

  defp interpreter_array_values(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %QuickBEAM.VM.Runtime.Object{kind: :array} = object} ->
        {:ok, Heap.array_entries(object)}

      _ ->
        {:error, :not_an_array}
    end
  end

  defp interpreter_array_values(_value, _execution), do: {:error, :not_an_array}

  defp continue(frame, execution), do: run(next_frame(frame), execution)
  defp next_frame(frame), do: %{frame | pc: frame.pc + 1}

  defp execute_opcode({:next, frame, execution}), do: continue(frame, execution)
  defp execute_opcode({:run, frame, execution}), do: run(frame, execution)
  defp execute_opcode({:return, value, execution}), do: return_value(value, execution)
  defp execute_opcode({:return_async, value, execution}), do: complete_async(value, execution)

  defp execute_opcode({:throw, reason, frame, execution}),
    do: raise_js(reason, frame, execution)

  defp execute_opcode({:error, reason, execution}), do: {:error, reason, execution}

  defp execute_opcode({:invoke, callable, arguments, this, caller, execution, tail?}),
    do: dispatch_call(callable, arguments, this, next_frame(caller), execution, tail?)

  defp execute_opcode({:invoke_constructor, constructor, arguments, instance, caller, execution}) do
    boundary = %Boundary.Constructor{
      instance: instance,
      caller: next_frame(caller),
      depth: execution.depth
    }

    dispatch_call(constructor, arguments, instance, boundary, execution, false)
  end

  defp execute_opcode(
         {:invoke_super_constructor, constructor, arguments, instance, caller, execution}
       ) do
    boundary = %Boundary.Constructor{
      instance: instance,
      caller: next_frame(caller),
      depth: execution.depth
    }

    dispatch_call(constructor, arguments, instance, boundary, execution, false)
  end

  defp execute_opcode({:await_promise, promise, frame, execution}) do
    case detach_async(frame, execution, promise) do
      {:ok, result} -> result
      :no_async_boundary -> suspend_promise_legacy(frame, execution, promise)
    end
  end

  defp execute_opcode({:await_legacy, reference, frame, execution}) do
    continuation = %Continuation{
      frame: next_frame(frame),
      execution: execution,
      awaiting: reference
    }

    {:suspended, continuation}
  end

  defp execute_opcode({:await_immediate, result, frame, execution}),
    do: await_immediate(result, frame, execution)

  defp execute_opcode({:invoke_getter, getter, receiver, frame, execution}) do
    boundary = %Boundary.Accessor{
      mode: :get,
      caller: next_frame(frame),
      depth: execution.depth
    }

    dispatch_call(getter, [], receiver, boundary, execution, false)
  end

  defp execute_opcode({:invoke_setter, setter, value, object, frame, execution}) do
    boundary = %Boundary.Accessor{
      mode: :set,
      caller: next_frame(frame),
      depth: execution.depth
    }

    dispatch_call(setter, [value], object, boundary, execution, false)
  end

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

  defp install_host_globals(execution, profile) do
    template = host_template(profile)
    user_globals = execution.globals
    validate_host_global_conflicts!(user_globals, template.globals)

    globals =
      template.globals
      |> Map.merge(user_globals)
      |> Map.put("Beam", Map.fetch!(template.globals, "Beam"))
      |> Map.put("globalThis", Map.fetch!(template.globals, "globalThis"))

    execution = %{
      execution
      | default_prototypes: template.default_prototypes,
        error_prototypes: template.error_prototypes,
        globals: globals,
        heap: template.heap,
        next_cell_id: template.next_cell_id,
        next_object_id: template.next_object_id,
        next_promise_id: template.next_promise_id,
        next_symbol_id: template.next_symbol_id
    }

    Memory.charge(execution, template.memory_used)
  end

  defp host_template(profile) do
    key = {@host_template_cache, profile}
    generation = Registry.generation()

    case :persistent_term.get(key, :missing) do
      {^generation, template} ->
        template

      _missing_or_stale ->
        template = build_host_template(profile)
        :persistent_term.put(key, {generation, template})
        template
    end
  end

  defp build_host_template(profile) do
    execution = %State{
      atoms: {},
      max_stack_depth: 1,
      remaining_steps: 1,
      step_limit: 1
    }

    build_host_globals(execution, profile)
  end

  defp build_host_globals(execution, profile) do
    execution = BuiltinRuntime.install(execution, profile)
    {beam, execution} = Heap.allocate(execution)

    {:ok, execution} =
      Property.define(beam, "call", {:host_function, :beam_call}, execution)

    {global_this, execution} = Heap.allocate(execution, :ordinary, internal: :global_object)

    globals =
      execution.globals
      |> Map.put_new("Infinity", :infinity)
      |> Map.put_new("NaN", :nan)
      |> Map.put_new("undefined", :undefined)
      |> Map.put("Beam", beam)
      |> Map.put("globalThis", global_this)

    %{execution | globals: globals}
  end

  defp validate_host_global_conflicts!(user_globals, template_globals) do
    protected_names = Map.keys(template_globals) -- (@host_override_names ++ @host_user_names)

    case Enum.find(protected_names, &Map.has_key?(user_globals, &1)) do
      nil -> :ok
      name -> raise ArgumentError, "builtin #{name} conflicts with an installed global"
    end
  end

  defp start_host_call(arguments, caller, execution, tail?) do
    case Async.start_host_call(arguments, execution) do
      {:ok, promise, execution} -> complete_call_result(promise, caller, execution, tail?)
      {:error, reason, execution} -> raise_js_from_caller(reason, caller, execution)
    end
  end

  defp raise_js(reason, frame, execution),
    do: reason |> Exception.throw_at(frame, execution) |> execute_exception()

  defp raise_js_from_caller(reason, caller, execution),
    do: reason |> Exception.throw_from(caller, execution) |> execute_exception()

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
         %State{callers: [%Boundary.Async{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    boundary |> Async.complete({:ok, value}, execution) |> execute_async()
  end

  defp complete_async(value, execution), do: return_value(value, execution)

  defp return_value(value, %State{callers: []} = execution),
    do: {:ok, value, %{execution | depth: 0}}

  defp return_value(value, %State{callers: [%Boundary.Async{} | _]} = execution),
    do: complete_async(value, execution)

  defp return_value(
         value,
         %State{callers: [%Boundary.ObjectAssign{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    complete_call_result(value, boundary, execution, false)
  end

  defp return_value(
         value,
         %State{callers: [%Boundary.ThenGetter{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    complete_then_getter(value, boundary, execution)
  end

  defp return_value(
         value,
         %State{callers: [%Boundary.Accessor{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    complete_accessor(value, boundary, execution)
  end

  defp return_value(
         value,
         %State{callers: [%Boundary.Constructor{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    complete_constructor(value, boundary, execution)
  end

  defp return_value(
         value,
         %State{callers: [%Boundary.Iterator{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    value |> Iterator.resume(boundary, execution) |> execute_invocation()
  end

  defp return_value(
         value,
         %State{callers: [%Boundary.Reaction{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    complete_reaction(boundary, value, execution)
  end

  defp return_value(
         _value,
         %State{callers: [%Boundary.PromiseExecutor{} = boundary | callers]} = execution
       ) do
    execution = %{execution | callers: callers, depth: boundary.depth}
    complete_executor(boundary, execution)
  end

  defp return_value(
         _value,
         %State{callers: [%Boundary.Thenable{} = boundary | callers]} = execution
       ) do
    {:idle, %{execution | callers: callers, depth: boundary.depth}}
  end

  defp return_value(value, %State{callers: [%Native{} = native | callers]} = execution) do
    execution = %{execution | callers: callers, depth: execution.depth - 1}
    resume_native(value, native, execution)
  end

  defp return_value(value, %State{callers: [%Frame{} = caller | callers]} = execution) do
    execution = %{execution | callers: callers, depth: execution.depth - 1}
    run(%{caller | stack: [value | caller.stack]}, execution)
  end
end
