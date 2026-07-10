defmodule QuickBEAM.VM.Interpreter do
  @moduledoc false

  import Bitwise

  alias QuickBEAM.VM.{
    Continuation,
    Execution,
    Frame,
    Function,
    Opcodes,
    PredefinedAtoms,
    Program,
    Value
  }

  @default_max_steps 5_000_000
  @default_max_stack_depth 1_000

  @type result ::
          {:ok, term()}
          | {:error, term()}
          | {:suspended, Continuation.t()}

  @spec eval(Program.t(), keyword()) :: result()
  def eval(%Program{} = program, opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)

    execution = %Execution{
      atoms: program.atoms,
      globals: Map.new(Keyword.get(opts, :vars, %{})),
      max_stack_depth: Keyword.get(opts, :max_stack_depth, @default_max_stack_depth),
      remaining_steps: max_steps,
      step_limit: max_steps
    }

    frame = new_frame(program.root, program.root, [], :undefined, {})

    normalize_result(run(frame, execution))
  end

  @spec resume(Continuation.t(), {:ok, term()} | {:error, term()}) :: result()
  def resume(%Continuation{} = continuation, {:ok, value}) do
    frame = %{continuation.frame | stack: [value | continuation.frame.stack]}

    normalize_result(run(frame, continuation.execution))
  end

  def resume(%Continuation{} = continuation, {:error, reason}) do
    normalize_result(raise_js(reason, continuation.frame, continuation.execution))
  end

  defp normalize_result({:ok, value, _execution}), do: {:ok, value}
  defp normalize_result({:error, reason, _execution}), do: {:error, reason}
  defp normalize_result({:suspended, continuation}), do: {:suspended, continuation}

  defp enter_call(callable, args, this, caller, execution, tail?) do
    with {:ok, function, closure_refs} <- callable_parts(callable) do
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
    else
      {:error, reason} -> raise_js(reason, caller, execution)
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

  defp execute(:special_object, [2], frame, execution),
    do: push(frame, execution, frame.callable)

  defp execute(:special_object, [_type], frame, execution),
    do: push(frame, execution, :undefined)

  defp execute(:drop, [], %{stack: [_value | stack]} = frame, execution),
    do: continue(%{frame | stack: stack}, execution)

  defp execute(:dup, [], %{stack: [value | _]} = frame, execution),
    do: continue(%{frame | stack: [value | frame.stack]}, execution)

  defp execute(:dup1, [], %{stack: [a, b | stack]} = frame, execution),
    do: continue(%{frame | stack: [a, b, a, b | stack]}, execution)

  defp execute(:dup2, [], %{stack: [a, b | stack]} = frame, execution),
    do: continue(%{frame | stack: [a, b, a, b | stack]}, execution)

  defp execute(:nip, [], %{stack: [a, _b | stack]} = frame, execution),
    do: continue(%{frame | stack: [a | stack]}, execution)

  defp execute(:nip_catch, [], frame, execution),
    do: execute(:nip, [], frame, execution)

  defp execute(:nip1, [], %{stack: [a, b, _c | stack]} = frame, execution),
    do: continue(%{frame | stack: [a, b | stack]}, execution)

  defp execute(:swap, [], %{stack: [a, b | stack]} = frame, execution),
    do: continue(%{frame | stack: [b, a | stack]}, execution)

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
  defp execute(:typeof, [], frame, execution), do: unary(frame, execution, &Value.typeof/1)
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
    push(frame, execution, callable)
  end

  defp execute(:fclosure8, [index], frame, execution),
    do: execute(:fclosure, [index], frame, execution)

  defp execute(:call, [argument_count], frame, execution),
    do: call(frame, execution, argument_count, false)

  defp execute(:tail_call, [argument_count], frame, execution),
    do: call(frame, execution, argument_count, true)

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

  defp execute(:await, [], %{stack: [{:pending, _reference} | stack]} = frame, execution) do
    continuation = %Continuation{frame: next_frame(%{frame | stack: stack}), execution: execution}
    {:suspended, continuation}
  end

  defp execute(:await, [], %{stack: [{:resolved, value} | stack]} = frame, execution),
    do: continue(%{frame | stack: [value | stack]}, execution)

  defp execute(:await, [], %{stack: [{:rejected, reason} | stack]} = frame, execution),
    do: raise_js(reason, %{frame | stack: stack}, execution)

  defp execute(:await, [], frame, execution), do: continue(frame, execution)

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
        enter_call(callable, Enum.reverse(arguments), :undefined, caller, execution, tail?)

      _ ->
        {:error, {:invalid_stack, :call}, execution}
    end
  end

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

  defp unwind_caller(reason, %Execution{callers: [caller | callers]} = execution) do
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

  defp return_value(value, %Execution{callers: [caller | callers]} = execution) do
    execution = %{execution | callers: callers, depth: execution.depth - 1}
    run(%{caller | stack: [value | caller.stack]}, execution)
  end

  defp update_local(frame, execution, index, operation) do
    value = read_slot(elem(frame.locals, index), execution)
    {locals, execution} = write_tuple_slot(frame.locals, index, operation.(value), execution)
    continue(%{frame | locals: locals}, execution)
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
