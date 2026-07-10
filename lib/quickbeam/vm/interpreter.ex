defmodule QuickBEAM.VM.Interpreter do
  @moduledoc false

  import Bitwise

  alias QuickBEAM.VM.{
    Builtins,
    Continuation,
    Execution,
    Export,
    Frame,
    Function,
    Heap,
    Memory,
    NativeFrame,
    Opcodes,
    PredefinedAtoms,
    Program,
    Promise,
    PromiseReference,
    Reference,
    RegExp,
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

  @doc false
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

  @doc false
  def resume_raw(%Continuation{} = continuation, {:ok, value}) do
    frame = %{continuation.frame | stack: [value | continuation.frame.stack]}
    run(frame, continuation.execution)
  end

  def resume_raw(%Continuation{} = continuation, {:error, reason}) do
    raise_js(reason, continuation.frame, continuation.execution)
  end

  @doc false
  def finish({:ok, value, execution}), do: Export.value(value, execution)
  def finish({:error, reason, _execution}), do: {:error, reason}
  def finish({:suspended, continuation}), do: {:suspended, continuation}

  defp enter_call(callable, args, this, caller, execution, tail?, frame_callable \\ nil) do
    with {:ok, function, closure_refs} <- callable_parts(callable) do
      depth = if tail?, do: execution.depth, else: execution.depth + 1

      if depth > execution.max_stack_depth do
        {:error, {:limit_exceeded, :stack_depth, depth}, execution}
      else
        execution =
          if tail?,
            do: execution,
            else: %{execution | callers: [caller | execution.callers], depth: depth}

        frame_callable = frame_callable || callable
        run(new_frame(function, frame_callable, args, this, closure_refs), execution)
      end
    else
      {:error, reason} -> raise_js(call_error(reason, caller), caller, execution)
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
    do: return_value(value, execution)

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
    case Promise.state(execution, promise) do
      :pending ->
        continuation = %Continuation{
          frame: next_frame(%{frame | stack: stack}),
          execution: execution,
          awaiting: promise
        }

        {:suspended, continuation}

      {:fulfilled, value} ->
        suspend_microtask({:ok, value}, %{frame | stack: stack}, execution)

      {:rejected, reason} ->
        suspend_microtask({:error, reason}, %{frame | stack: stack}, execution)
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
    do: suspend_microtask({:ok, value}, %{frame | stack: stack}, execution)

  defp execute(:await, [], %{stack: [{:rejected, reason} | stack]} = frame, execution),
    do: suspend_microtask({:error, reason}, %{frame | stack: stack}, execution)

  defp execute(:await, [], %{stack: [value | stack]} = frame, execution),
    do: suspend_microtask({:ok, value}, %{frame | stack: stack}, execution)

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
        caller = %{next_frame(frame) | stack: rest}
        dispatch_call(constructor, Enum.reverse(arguments), :undefined, caller, execution, false)

      _ ->
        {:error, {:invalid_stack, :call_constructor}, execution}
    end
  end

  defp dispatch_call({:host_function, :beam_call}, arguments, _this, caller, execution, tail?),
    do: start_host_call(arguments, caller, execution, tail?)

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
    case {Promise.state(execution, promise), arguments} do
      {{:fulfilled, value}, [callback | _]} ->
        dispatch_call(callback, [value], :undefined, caller, execution, tail?)

      {{:rejected, reason}, [_fulfilled, rejected | _]} ->
        dispatch_call(rejected, [reason], :undefined, caller, execution, tail?)

      _ ->
        if tail?,
          do: return_value(promise, execution),
          else: run(%{caller | stack: [promise | caller.stack]}, execution)
    end
  end

  defp dispatch_call(%Reference{} = reference, arguments, this, caller, execution, tail?) do
    case Builtins.callable(execution, reference) do
      nil ->
        raise_js(call_error({:not_callable, reference}, caller), caller, execution)

      callable when elem(callable, 0) in [:builtin, :builtin_method, :primitive_method] ->
        dispatch_call(callable, arguments, this, caller, execution, tail?)

      callable ->
        enter_call(callable, arguments, this, caller, execution, tail?, reference)
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
        if tail?,
          do: return_value(value, execution),
          else: run(%{caller | stack: [value | caller.stack]}, execution)

      {:error, reason, execution} ->
        raise_js({:type_error, reason}, caller, execution)
    end
  end

  defp dispatch_call(callable, arguments, this, caller, execution, tail?),
    do: enter_call(callable, arguments, this, caller, execution, tail?)

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
        raise_js({:type_error, :reduce_of_empty_array}, caller, execution)
      else
        invoke_native_next(native, execution)
      end
    else
      {:error, reason} -> raise_js({:type_error, reason}, caller, execution)
      [] -> raise_js({:type_error, :missing_callback}, caller, execution)
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
    do: raise_js({:type_error, :invalid_beam_call}, caller, execution)

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

  defp call_error(reason, %NativeFrame{caller: caller}), do: call_error(reason, caller)

  defp call_error(reason, caller) do
    pc = max(caller.pc - 1, 0)
    {reason, {caller.function.name, pc, elem(caller.function.source_positions, pc)}}
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
                :promise_method
              ],
       do: "function"

  defp type_of(value, _execution), do: Value.typeof(value)

  defp get_property_and_continue(object, key, stack, frame, execution) do
    case get_property(object, key, execution) do
      {:ok, value} ->
        continue(%{frame | stack: [value | stack]}, execution)

      {:error, reason} ->
        location =
          {frame.function.name, frame.pc, elem(frame.function.source_positions, frame.pc), key}

        raise_js({:type_error, {reason, location}}, %{frame | stack: stack}, execution)
    end
  end

  defp put_property_and_continue(object, key, value, stack, frame, execution) do
    case put_property(object, key, value, execution) do
      {:ok, execution} ->
        continue(%{frame | stack: stack}, execution)

      {:error, reason} ->
        location =
          {frame.function.name, frame.pc, elem(frame.function.source_positions, frame.pc)}

        raise_js({:type_error, {reason, location}}, %{frame | stack: stack}, execution)
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

  defp get_property(%PromiseReference{}, "then", _execution), do: {:ok, {:promise_method, "then"}}

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
                :promise_method
              ],
       do: {:ok, {:function_method, key}}

  defp get_property(object, key, _execution) when is_map(object) and not is_struct(object) do
    case Map.fetch(object, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:ok, map_string_key(object, key)}
    end
  end

  defp get_property(object, "length", _execution) when is_binary(object),
    do: {:ok, utf16_length(object)}

  defp get_property(object, key, _execution) when is_binary(object) and is_integer(key) do
    {:ok, String.at(object, key) || :undefined}
  end

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

  defp utf16_length(value) do
    value
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> byte_size()
    |> div(2)
  end

  defp raise_js(reason, %NativeFrame{caller: caller}, execution),
    do: raise_js(reason, caller, execution)

  defp raise_js(reason, frame, execution) do
    case split_at_catch(frame.stack) do
      {:caught, target, stack_below_catch} ->
        run(%{frame | pc: target, stack: [reason | stack_below_catch]}, execution)

      :uncaught ->
        unwind_caller(reason, execution)
    end
  end

  defp unwind_caller(reason, %Execution{callers: []} = execution),
    do: {:error, {:js_throw, reason}, execution}

  defp unwind_caller(reason, %Execution{callers: [%NativeFrame{} = native | callers]} = execution) do
    execution = %{execution | callers: callers, depth: execution.depth - 1}
    raise_js(reason, native.caller, execution)
  end

  defp unwind_caller(reason, %Execution{callers: [%Frame{} = caller | callers]} = execution) do
    execution = %{execution | callers: callers, depth: execution.depth - 1}
    raise_js(reason, caller, execution)
  end

  defp split_at_catch(stack) do
    case Enum.split_while(stack, &(!match?({:catch, _target}, &1))) do
      {_discarded, [{:catch, target} | stack]} -> {:caught, target, stack}
      {_discarded, []} -> :uncaught
    end
  end

  defp return_value(value, %Execution{callers: []} = execution),
    do: {:ok, value, execution}

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
