defmodule QuickBEAM.BeamVM.Interpreter do
  @moduledoc """
  Executes decoded QuickJS bytecode via multi-clause function dispatch.

  The interpreter pre-decodes bytecode into instruction tuples for O(1) indexed
  access, then runs a tail-recursive dispatch loop with one `defp run/4` clause
  per opcode family.

  ## JS value representation
    - number: Elixir integer or float
    - string: Elixir binary
    - boolean: true / false
    - null: nil
    - undefined: :undefined
    - object: {:ref, reference()}
    - function: {:function, Bytecode.Function.t()} | {:closure, map(), Bytecode.Function.t()}
    - array: {:array, list(), reference()}
  """

  alias QuickBEAM.BeamVM.{Bytecode, Decoder, Runtime}
  alias __MODULE__.Frame

  alias __MODULE__.{Values, Objects, Closures, Scope}
  import Values, except: [div: 2, band: 2, bor: 2, bxor: 2]
  import Objects, except: [put: 3]
  import Closures
  import Scope
  import Bitwise, only: [bnot: 1, &&&: 2]

  @default_gas 1_000_000_000

  @spec eval(Bytecode.Function.t()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun), do: eval(fun, [], %{})

  @spec eval(Bytecode.Function.t(), [term()], map()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun, args, opts), do: eval(fun, args, opts, {})

  @spec eval(Bytecode.Function.t(), [term()], map(), tuple()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun, args, opts, atoms) do
    gas = Map.get(opts, :gas, @default_gas)
    Process.put(:qb_atoms, atoms)
    unless Process.get(:qb_globals) do
      Process.put(:qb_globals, Runtime.global_bindings())
    end

    case Decoder.decode(fun.byte_code) do
      {:ok, instructions} ->
        instructions = List.to_tuple(instructions)
        locals = :erlang.make_tuple(max(fun.arg_count + fun.var_count, 1), :undefined)

        frame = %Frame{
          pc: 0,
          locals: locals,
          constants: fun.constants,
          var_refs: {},
          stack_size: fun.stack_size,
          instructions: instructions
        }

        try do
          result = run(frame, args, gas)
          {:ok, result}
        catch
          {:js_throw, val} -> {:error, {:js_throw, val}}
          {:js_return, val} -> {:ok, val}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  # ── Helpers ──

  defp advance(%Frame{pc: pc} = f), do: %{f | pc: pc + 1}
  defp jump(%Frame{} = f, target), do: %{f | pc: target}
  defp put_local(%Frame{locals: locals} = f, idx, val), do: %{f | locals: put_elem(locals, idx, val)}

  # ── Main dispatch loop ──

  defp run(_frame, _stack, gas) when gas <= 0 do
    throw({:error, {:out_of_gas, gas}})
  end

  defp run(%Frame{pc: pc, instructions: insns} = frame, stack, gas) do
    run(elem(insns, pc), frame, stack, gas)
  end

  # ── Push constants ──

  defp run({:push_i32, [val]}, frame, stack, gas), do: run(advance(frame), [val | stack], gas - 1)
  defp run({:push_i8, [val]}, frame, stack, gas), do: run(advance(frame), [val | stack], gas - 1)
  defp run({:push_i16, [val]}, frame, stack, gas), do: run(advance(frame), [val | stack], gas - 1)
  defp run({:push_minus1, _}, frame, stack, gas), do: run(advance(frame), [-1 | stack], gas - 1)
  defp run({:push_0, _}, frame, stack, gas), do: run(advance(frame), [0 | stack], gas - 1)
  defp run({:push_1, _}, frame, stack, gas), do: run(advance(frame), [1 | stack], gas - 1)
  defp run({:push_2, _}, frame, stack, gas), do: run(advance(frame), [2 | stack], gas - 1)
  defp run({:push_3, _}, frame, stack, gas), do: run(advance(frame), [3 | stack], gas - 1)
  defp run({:push_4, _}, frame, stack, gas), do: run(advance(frame), [4 | stack], gas - 1)
  defp run({:push_5, _}, frame, stack, gas), do: run(advance(frame), [5 | stack], gas - 1)
  defp run({:push_6, _}, frame, stack, gas), do: run(advance(frame), [6 | stack], gas - 1)
  defp run({:push_7, _}, frame, stack, gas), do: run(advance(frame), [7 | stack], gas - 1)

  defp run({:push_const, [idx]}, %Frame{constants: cpool} = frame, stack, gas) do
    run(advance(frame), [resolve_const(cpool, idx) | stack], gas - 1)
  end

  defp run({:push_const8, [idx]}, %Frame{constants: cpool} = frame, stack, gas) do
    run(advance(frame), [resolve_const(cpool, idx) | stack], gas - 1)
  end

  defp run({:push_atom_value, [atom_idx]}, frame, stack, gas) do
    run(advance(frame), [resolve_atom(atom_idx) | stack], gas - 1)
  end

  defp run({:undefined, []}, frame, stack, gas), do: run(advance(frame), [:undefined | stack], gas - 1)
  defp run({:null, []}, frame, stack, gas), do: run(advance(frame), [nil | stack], gas - 1)
  defp run({:push_false, []}, frame, stack, gas), do: run(advance(frame), [false | stack], gas - 1)
  defp run({:push_true, []}, frame, stack, gas), do: run(advance(frame), [true | stack], gas - 1)
  defp run({:push_empty_string, []}, frame, stack, gas), do: run(advance(frame), ["" | stack], gas - 1)
  defp run({:push_bigint_i32, [val]}, frame, stack, gas), do: run(advance(frame), [{:bigint, val} | stack], gas - 1)

  # ── Stack manipulation ──

  defp run({:drop, []}, frame, [_ | rest], gas), do: run(advance(frame), rest, gas - 1)
  defp run({:nip, []}, frame, [a, _b | rest], gas), do: run(advance(frame), [a | rest], gas - 1)
  defp run({:nip1, []}, frame, [a, b, _c | rest], gas), do: run(advance(frame), [a, b | rest], gas - 1)
  defp run({:dup, []}, frame, [a | _] = stack, gas), do: run(advance(frame), [a | stack], gas - 1)

  defp run({:dup1, []}, frame, [a, b | _] = stack, gas) do
    run(advance(frame), [a, b | stack], gas - 1)
  end

  defp run({:dup2, []}, frame, [a, b | _] = stack, gas) do
    run(advance(frame), [a, b, a, b | stack], gas - 1)
  end

  defp run({:dup3, []}, frame, [a, b, c | _] = stack, gas) do
    run(advance(frame), [a, b, c, a, b, c | stack], gas - 1)
  end

  defp run({:insert2, []}, frame, [a, b | rest], gas), do: run(advance(frame), [a, b, a | rest], gas - 1)
  defp run({:insert3, []}, frame, [a, b, c | rest], gas), do: run(advance(frame), [a, b, c, a | rest], gas - 1)
  defp run({:insert4, []}, frame, [a, b, c, d | rest], gas), do: run(advance(frame), [a, b, c, d, a | rest], gas - 1)
  defp run({:perm3, []}, frame, [a, b, c | rest], gas), do: run(advance(frame), [c, a, b | rest], gas - 1)
  defp run({:perm4, []}, frame, [a, b, c, d | rest], gas), do: run(advance(frame), [d, a, b, c | rest], gas - 1)
  defp run({:perm5, []}, frame, [a, b, c, d, e | rest], gas), do: run(advance(frame), [e, a, b, c, d | rest], gas - 1)
  defp run({:swap, []}, frame, [a, b | rest], gas), do: run(advance(frame), [b, a | rest], gas - 1)
  defp run({:swap2, []}, frame, [a, b, c, d | rest], gas), do: run(advance(frame), [c, d, a, b | rest], gas - 1)
  defp run({:rot3l, []}, frame, [a, b, c | rest], gas), do: run(advance(frame), [b, c, a | rest], gas - 1)
  defp run({:rot3r, []}, frame, [a, b, c | rest], gas), do: run(advance(frame), [c, a, b | rest], gas - 1)
  defp run({:rot4l, []}, frame, [a, b, c, d | rest], gas), do: run(advance(frame), [b, c, d, a | rest], gas - 1)
  defp run({:rot5l, []}, frame, [a, b, c, d, e | rest], gas), do: run(advance(frame), [b, c, d, e, a | rest], gas - 1)

  # ── Args ──

  defp run({:get_arg, [idx]}, frame, stack, gas), do: run(advance(frame), [get_arg_value(idx) | stack], gas - 1)
  defp run({:get_arg0, []}, frame, stack, gas), do: run(advance(frame), [get_arg_value(0) | stack], gas - 1)
  defp run({:get_arg1, []}, frame, stack, gas), do: run(advance(frame), [get_arg_value(1) | stack], gas - 1)
  defp run({:get_arg2, []}, frame, stack, gas), do: run(advance(frame), [get_arg_value(2) | stack], gas - 1)
  defp run({:get_arg3, []}, frame, stack, gas), do: run(advance(frame), [get_arg_value(3) | stack], gas - 1)

  # ── Locals ──

  defp run({:get_loc, [idx]}, %Frame{locals: locals, var_refs: vrefs} = frame, stack, gas) do
    run(advance(frame), [read_captured_local(idx, locals, vrefs) | stack], gas - 1)
  end

  defp run({:put_loc, [idx]}, %Frame{locals: locals, var_refs: vrefs} = frame, [val | rest], gas) do
    write_captured_local(idx, val, locals, vrefs)
    run(advance(put_local(frame, idx, val)), rest, gas - 1)
  end

  defp run({:set_loc, [idx]}, %Frame{locals: locals, var_refs: vrefs} = frame, [val | rest], gas) do
    write_captured_local(idx, val, locals, vrefs)
    run(advance(put_local(frame, idx, val)), [val | rest], gas - 1)
  end

  defp run({:set_loc_uninitialized, [idx]}, frame, stack, gas) do
    run(advance(put_local(frame, idx, :undefined)), stack, gas - 1)
  end

  defp run({:get_loc_check, [idx]}, %Frame{locals: locals} = frame, stack, gas) do
    val = elem(locals, idx)
    if val == :undefined, do: throw({:error, {:uninitialized_local, idx}})
    run(advance(frame), [val | stack], gas - 1)
  end

  defp run({:put_loc_check, [idx]}, frame, [val | rest], gas) do
    if val == :undefined, do: throw({:error, {:uninitialized_local, idx}})
    run(advance(put_local(frame, idx, val)), rest, gas - 1)
  end

  defp run({:put_loc_check_init, [idx]}, frame, [val | rest], gas) do
    run(advance(put_local(frame, idx, val)), rest, gas - 1)
  end

  defp run({:get_loc0_loc1, []}, %Frame{locals: locals} = frame, stack, gas) do
    run(advance(frame), [elem(locals, 1), elem(locals, 0) | stack], gas - 1)
  end

  # ── Variable references (closures) ──

  defp run({:get_var_ref, [idx]}, %Frame{var_refs: vrefs} = frame, stack, gas) do
    val = case elem(vrefs, idx) do
      {:cell, _} = cell -> read_cell(cell)
      other -> other
    end
    run(advance(frame), [val | stack], gas - 1)
  end

  defp run({:put_var_ref, [idx]}, %Frame{var_refs: vrefs} = frame, [val | rest], gas) do
    case elem(vrefs, idx) do
      {:cell, ref} -> write_cell({:cell, ref}, val)
      _ -> :ok
    end
    run(advance(frame), rest, gas - 1)
  end

  defp run({:set_var_ref, [idx]}, %Frame{var_refs: vrefs} = frame, [val | rest], gas) do
    case elem(vrefs, idx) do
      {:cell, ref} -> write_cell({:cell, ref}, val)
      _ -> :ok
    end
    run(advance(frame), [val | rest], gas - 1)
  end

  defp run({:close_loc, [_idx]}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)

  # ── Control flow ──

  defp run({:if_false, [target]}, frame, [val | rest], gas) do
    if falsy?(val),
      do: run(jump(frame, target), rest, gas - 1),
      else: run(advance(frame), rest, gas - 1)
  end

  defp run({:if_false8, [target]}, frame, [val | rest], gas) do
    if falsy?(val),
      do: run(jump(frame, target), rest, gas - 1),
      else: run(advance(frame), rest, gas - 1)
  end

  defp run({:if_true, [target]}, frame, [val | rest], gas) do
    if truthy?(val),
      do: run(jump(frame, target), rest, gas - 1),
      else: run(advance(frame), rest, gas - 1)
  end

  defp run({:if_true8, [target]}, frame, [val | rest], gas) do
    if truthy?(val),
      do: run(jump(frame, target), rest, gas - 1),
      else: run(advance(frame), rest, gas - 1)
  end

  defp run({:goto, [target]}, frame, stack, gas), do: run(jump(frame, target), stack, gas - 1)
  defp run({:goto8, [target]}, frame, stack, gas), do: run(jump(frame, target), stack, gas - 1)
  defp run({:goto16, [target]}, frame, stack, gas), do: run(jump(frame, target), stack, gas - 1)

  defp run({:return, []}, _frame, [val | _], _gas), do: throw({:js_return, val})

  defp run({:return_undef, []}, _frame, _stack, _gas) do
    throw({:js_return, Process.get(:qb_this, :undefined)})
  end

  # ── Arithmetic ──

  defp run({:add, []}, frame, [b, a | rest], gas), do: run(advance(frame), [add(a, b) | rest], gas - 1)
  defp run({:sub, []}, frame, [b, a | rest], gas), do: run(advance(frame), [sub(a, b) | rest], gas - 1)
  defp run({:mul, []}, frame, [b, a | rest], gas), do: run(advance(frame), [mul(a, b) | rest], gas - 1)
  defp run({:div, []}, frame, [b, a | rest], gas), do: run(advance(frame), [Values.div(a, b) | rest], gas - 1)
  defp run({:mod, []}, frame, [b, a | rest], gas), do: run(advance(frame), [mod(a, b) | rest], gas - 1)
  defp run({:pow, []}, frame, [b, a | rest], gas), do: run(advance(frame), [pow(a, b) | rest], gas - 1)

  # ── Bitwise ──

  defp run({:band, []}, frame, [b, a | rest], gas), do: run(advance(frame), [Values.band(a, b) | rest], gas - 1)
  defp run({:bor, []}, frame, [b, a | rest], gas), do: run(advance(frame), [Values.bor(a, b) | rest], gas - 1)
  defp run({:bxor, []}, frame, [b, a | rest], gas), do: run(advance(frame), [Values.bxor(a, b) | rest], gas - 1)
  defp run({:shl, []}, frame, [b, a | rest], gas), do: run(advance(frame), [shl(a, b) | rest], gas - 1)
  defp run({:sar, []}, frame, [b, a | rest], gas), do: run(advance(frame), [sar(a, b) | rest], gas - 1)
  defp run({:shr, []}, frame, [b, a | rest], gas), do: run(advance(frame), [shr(a, b) | rest], gas - 1)

  # ── Comparison ──

  defp run({:lt, []}, frame, [b, a | rest], gas), do: run(advance(frame), [lt(a, b) | rest], gas - 1)
  defp run({:lte, []}, frame, [b, a | rest], gas), do: run(advance(frame), [lte(a, b) | rest], gas - 1)
  defp run({:gt, []}, frame, [b, a | rest], gas), do: run(advance(frame), [gt(a, b) | rest], gas - 1)
  defp run({:gte, []}, frame, [b, a | rest], gas), do: run(advance(frame), [gte(a, b) | rest], gas - 1)
  defp run({:eq, []}, frame, [b, a | rest], gas), do: run(advance(frame), [eq(a, b) | rest], gas - 1)
  defp run({:neq, []}, frame, [b, a | rest], gas), do: run(advance(frame), [neq(a, b) | rest], gas - 1)
  defp run({:strict_eq, []}, frame, [b, a | rest], gas), do: run(advance(frame), [strict_eq(a, b) | rest], gas - 1)
  defp run({:strict_neq, []}, frame, [b, a | rest], gas), do: run(advance(frame), [not strict_eq(a, b) | rest], gas - 1)

  # ── Unary ──

  defp run({:neg, []}, frame, [a | rest], gas), do: run(advance(frame), [neg(a) | rest], gas - 1)
  defp run({:plus, []}, frame, [a | rest], gas), do: run(advance(frame), [to_number(a) | rest], gas - 1)
  defp run({:inc, []}, frame, [a | rest], gas), do: run(advance(frame), [add(a, 1) | rest], gas - 1)
  defp run({:dec, []}, frame, [a | rest], gas), do: run(advance(frame), [sub(a, 1) | rest], gas - 1)
  defp run({:post_inc, []}, frame, [a | rest], gas), do: run(advance(frame), [add(a, 1), a | rest], gas - 1)
  defp run({:post_dec, []}, frame, [a | rest], gas), do: run(advance(frame), [sub(a, 1), a | rest], gas - 1)

  defp run({:inc_loc, [idx]}, %Frame{locals: locals, var_refs: vrefs} = frame, stack, gas) do
    new_val = add(elem(locals, idx), 1)
    write_captured_local(idx, new_val, locals, vrefs)
    run(advance(put_local(frame, idx, new_val)), stack, gas - 1)
  end

  defp run({:dec_loc, [idx]}, %Frame{locals: locals, var_refs: vrefs} = frame, stack, gas) do
    new_val = sub(elem(locals, idx), 1)
    write_captured_local(idx, new_val, locals, vrefs)
    run(advance(put_local(frame, idx, new_val)), stack, gas - 1)
  end

  defp run({:add_loc, [idx]}, %Frame{locals: locals, var_refs: vrefs} = frame, [val | rest], gas) do
    new_val = add(elem(locals, idx), val)
    write_captured_local(idx, new_val, locals, vrefs)
    run(advance(put_local(frame, idx, new_val)), rest, gas - 1)
  end

  defp run({:not, []}, frame, [a | rest], gas), do: run(advance(frame), [bnot(to_int32(a)) | rest], gas - 1)
  defp run({:lnot, []}, frame, [a | rest], gas), do: run(advance(frame), [not truthy?(a) | rest], gas - 1)
  defp run({:typeof, []}, frame, [a | rest], gas), do: run(advance(frame), [typeof(a) | rest], gas - 1)

  # ── Function creation / calls ──

  defp run({:fclosure, [idx]}, %Frame{constants: cpool, locals: locals, var_refs: vrefs} = frame, stack, gas) do
    closure = build_closure(resolve_const(cpool, idx), locals, vrefs)
    run(advance(frame), [closure | stack], gas - 1)
  end

  defp run({:fclosure8, [idx]}, %Frame{constants: cpool, locals: locals, var_refs: vrefs} = frame, stack, gas) do
    closure = build_closure(resolve_const(cpool, idx), locals, vrefs)
    run(advance(frame), [closure | stack], gas - 1)
  end

  defp run({:call, [argc]}, frame, stack, gas), do: call_function(frame, stack, argc, gas)
  defp run({:tail_call, [argc]}, _frame, stack, gas), do: tail_call(stack, argc, gas)
  defp run({:call_method, [argc]}, frame, stack, gas), do: call_method(frame, stack, argc, gas)
  defp run({:tail_call_method, [argc]}, _frame, stack, gas), do: tail_call_method(stack, argc, gas)

  # ── Objects ──

  defp run({:object, []}, frame, stack, gas) do
    ref = make_ref()
    Process.put({:qb_obj, ref}, %{})
    run(advance(frame), [{:obj, ref} | stack], gas - 1)
  end

  defp run({:get_field, [atom_idx]}, frame, [obj | rest], gas) do
    run(advance(frame), [Runtime.get_property(obj, resolve_atom(atom_idx)) | rest], gas - 1)
  end

  defp run({:put_field, [atom_idx]}, frame, [val, obj | rest], gas) do
    Objects.put(obj, resolve_atom(atom_idx), val)
    run(advance(frame), [obj | rest], gas - 1)
  end

  defp run({:define_field, [atom_idx]}, frame, [val, obj | rest], gas) do
    Objects.put(obj, resolve_atom(atom_idx), val)
    run(advance(frame), [obj | rest], gas - 1)
  end

  defp run({:get_array_el, []}, frame, [idx, obj | rest], gas) do
    run(advance(frame), [get_array_el(obj, idx) | rest], gas - 1)
  end

  defp run({:put_array_el, []}, frame, [val, idx, obj | rest], gas) do
    put_array_el(obj, idx, val)
    run(advance(frame), [obj | rest], gas - 1)
  end

  defp run({:get_length, []}, frame, [obj | rest], gas) do
    len = case obj do
      {:obj, ref} ->
        case Process.get({:qb_obj, ref}) do
          list when is_list(list) -> length(list)
          map when is_map(map) -> map_size(map)
          _ -> 0
        end
      list when is_list(list) -> length(list)
      s when is_binary(s) -> Runtime.js_string_length(s)
      _ -> :undefined
    end
    run(advance(frame), [len | rest], gas - 1)
  end

  defp run({:array_from, [argc]}, frame, stack, gas) do
    {elems, rest} = Enum.split(stack, argc)
    ref = System.unique_integer([:positive])
    Process.put({:qb_obj, ref}, Enum.reverse(elems))
    run(advance(frame), [{:obj, ref} | rest], gas - 1)
  end

  # ── Misc / no-op ──

  defp run({:nop, []}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)
  defp run({:to_object, []}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)
  defp run({:to_propkey, []}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)
  defp run({:to_propkey2, []}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)
  defp run({:check_ctor, []}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)

  defp run({:check_ctor_return, []}, frame, [val | rest], gas) do
    result = case val do
      {:obj, _} = obj -> obj
      _ -> Process.get(:qb_this, :undefined)
    end
    run(advance(frame), [result | rest], gas - 1)
  end

  defp run({:set_name, [_atom_idx]}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)

  defp run({:throw, []}, %Frame{locals: locals, constants: cpool, var_refs: vrefs, stack_size: ssz, instructions: insns}, [val | _], gas) do
    case Process.get(:qb_catch_stack, []) do
      [{target, catch_stack} | rest_catch] ->
        Process.put(:qb_catch_stack, rest_catch)
        frame = %Frame{pc: target, locals: locals, constants: cpool, var_refs: vrefs, stack_size: ssz, instructions: insns}
        run(frame, [val | catch_stack], gas - 1)
      [] ->
        throw({:js_throw, val})
    end
  end

  defp run({:is_undefined, []}, frame, [a | rest], gas), do: run(advance(frame), [a == :undefined | rest], gas - 1)
  defp run({:is_null, []}, frame, [a | rest], gas), do: run(advance(frame), [a == nil | rest], gas - 1)
  defp run({:is_undefined_or_null, []}, frame, [a | rest], gas), do: run(advance(frame), [a == :undefined or a == nil | rest], gas - 1)
  defp run({:invalid, []}, _frame, _stack, _gas), do: throw({:error, :invalid_opcode})

  defp run({:get_var_undef, [atom_idx]}, frame, stack, gas) do
    val = case resolve_global(atom_idx) do
      {:found, v} -> v
      :not_found -> :undefined
    end
    run(advance(frame), [val | stack], gas - 1)
  end

  defp run({:get_var, [atom_idx]}, frame, stack, gas) do
    case resolve_global(atom_idx) do
      {:found, val} ->
        run(advance(frame), [val | stack], gas - 1)
      :not_found ->
        throw({:js_throw, %{"message" => "#{resolve_atom(atom_idx)} is not defined", "name" => "ReferenceError"}})
    end
  end

  defp run({:put_var, [atom_idx]}, frame, [val | rest], gas) do
    set_global(atom_idx, val)
    run(advance(frame), rest, gas - 1)
  end

  defp run({:put_var_init, [atom_idx]}, frame, [val | rest], gas) do
    set_global(atom_idx, val)
    run(advance(frame), rest, gas - 1)
  end

  defp run({:define_var, [atom_idx, _scope]}, frame, [val | rest], gas) do
    Process.put({:qb_var, resolve_atom(atom_idx)}, val)
    run(advance(frame), rest, gas - 1)
  end

  defp run({:check_define_var, [atom_idx, _scope]}, frame, stack, gas) do
    Process.delete({:qb_var, resolve_atom(atom_idx)})
    run(advance(frame), stack, gas - 1)
  end

  defp run({:get_field2, [atom_idx]}, frame, [obj | rest], gas) do
    val = Runtime.get_property(obj, resolve_atom(atom_idx))
    run(advance(frame), [val, obj | rest], gas - 1)
  end

  # ── try/catch ──

  defp run({:catch, [target]}, frame, stack, gas) do
    catch_stack = Process.get(:qb_catch_stack, [])
    Process.put(:qb_catch_stack, [{target, stack} | catch_stack])
    run(advance(frame), [target | stack], gas - 1)
  end

  defp run({:nip_catch, []}, frame, [a, _catch_offset | rest], gas) do
    [_ | rest_catch] = Process.get(:qb_catch_stack, [])
    Process.put(:qb_catch_stack, rest_catch)
    run(advance(frame), [a | rest], gas - 1)
  end

  # ── for-in ──

  defp run({:for_in_start, []}, frame, [obj | rest], gas) do
    keys = case obj do
      {:obj, ref} -> Map.keys(Process.get({:qb_obj, ref}, %{}))
      map when is_map(map) -> Map.keys(map)
      _ -> []
    end
    run(advance(frame), [{:for_in_iterator, keys} | rest], gas - 1)
  end

  defp run({:for_in_next, []}, frame, [{:for_in_iterator, [key | rest_keys]} | rest], gas) do
    run(advance(frame), [false, key, {:for_in_iterator, rest_keys} | rest], gas - 1)
  end

  defp run({:for_in_next, []}, frame, [iter | rest], gas) do
    run(advance(frame), [true, :undefined, iter | rest], gas - 1)
  end

  # ── new / constructor ──

  defp run({:call_constructor, [argc]}, frame, stack, gas) do
    {args, [_new_target, ctor | rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)

    this_ref = make_ref()
    proto = Process.get({:qb_class_proto, :erlang.phash2(ctor)})
    init = if proto, do: %{"__proto__" => proto}, else: %{}
    Process.put({:qb_obj, this_ref}, init)
    this_obj = {:obj, this_ref}
    prev_this = Process.get(:qb_this)
    Process.put(:qb_this, this_obj)

    result = try do
      case ctor do
        %Bytecode.Function{} = f ->
          cell_ref = make_ref()
          Process.put({:qb_cell, cell_ref}, false)
          do_invoke(f, rev_args, [{:cell, cell_ref}], gas)

        {:closure, captured, %Bytecode.Function{} = f} ->
          cell_ref = make_ref()
          Process.put({:qb_cell, cell_ref}, false)
          var_refs = for cv <- f.closure_vars do
            Map.get(captured, cv.var_idx, {:cell, cell_ref})
          end
          var_refs = if var_refs == [], do: [{:cell, cell_ref}], else: var_refs
          do_invoke(f, rev_args, var_refs, gas)

        {:builtin, name, cb} when is_function(cb, 1) ->
          obj = cb.(rev_args)
          if name in ~w(Error TypeError RangeError SyntaxError ReferenceError URIError EvalError) do
            case obj do
              {:obj, ref} ->
                existing = Process.get({:qb_obj, ref}, %{})
                if is_map(existing) and not Map.has_key?(existing, "name") do
                  Process.put({:qb_obj, ref}, Map.put(existing, "name", name))
                end
              _ -> :ok
            end
          end
          obj

        _ -> this_obj
      end
    after
      if prev_this, do: Process.put(:qb_this, prev_this), else: Process.delete(:qb_this)
    end

    result = case result do
      {:obj, _} = obj -> obj
      _ -> this_obj
    end

    case {result, Process.get({:qb_class_proto, :erlang.phash2(ctor)})} do
      {{:obj, rref}, {:obj, _} = proto} ->
        rmap = Process.get({:qb_obj, rref}, %{})
        unless Map.has_key?(rmap, "__proto__") do
          Process.put({:qb_obj, rref}, Map.put(rmap, "__proto__", proto))
        end
      _ -> :ok
    end

    run(advance(frame), [result | rest], gas - 1)
  end

  defp run({:init_ctor, []}, frame, stack, gas) do
    this = Process.get(:qb_this, :undefined)
    run(advance(frame), [this | stack], gas - 1)
  end

  # ── instanceof ──

  defp run({:instanceof, []}, frame, [_ctor, _obj | rest], gas) do
    run(advance(frame), [false | rest], gas - 1)
  end

  # ── delete ──

  defp run({:delete, []}, frame, [key, obj | rest], gas) do
    case obj do
      {:obj, ref} ->
        map = Process.get({:qb_obj, ref}, %{})
        if is_map(map), do: Process.put({:qb_obj, ref}, Map.delete(map, key))
      _ -> :ok
    end
    run(advance(frame), [true | rest], gas - 1)
  end

  defp run({:delete_var, [_atom_idx]}, frame, stack, gas), do: run(advance(frame), [true | stack], gas - 1)

  # ── in operator ──

  defp run({:in, []}, frame, [obj, key | rest], gas) do
    run(advance(frame), [has_property(obj, key) | rest], gas - 1)
  end

  # ── regexp literal ──

  defp run({:regexp, []}, frame, [pattern, flags | rest], gas) do
    run(advance(frame), [{:regexp, pattern, flags} | rest], gas - 1)
  end

  # ── spread / array construction ──

  defp run({:append, []}, frame, [obj, idx, arr | rest], gas) do
    src_list = case obj do
      list when is_list(list) -> list
      {:obj, ref} -> Process.get({:qb_obj, ref}, [])
      _ -> []
    end
    arr_list = case arr do
      list when is_list(list) -> list
      {:obj, ref} -> Process.get({:qb_obj, ref}, [])
      _ -> []
    end
    merged = arr_list ++ src_list
    new_idx = (if is_integer(idx), do: idx, else: Runtime.to_int(idx)) + length(src_list)
    merged_obj = case arr do
      {:obj, ref} ->
        Process.put({:qb_obj, ref}, merged)
        {:obj, ref}
      _ -> merged
    end
    run(advance(frame), [new_idx, merged_obj | rest], gas - 1)
  end

  defp run({:define_array_el, []}, frame, [val, idx, obj | rest], gas) do
    obj2 = case obj do
      list when is_list(list) ->
        i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
        if i >= 0 and i < length(list) do
          List.replace_at(list, i, val)
        else
          list ++ List.duplicate(:undefined, max(0, i - length(list))) ++ [val]
        end
      {:obj, ref} ->
        stored = Process.get({:qb_obj, ref}, [])
        cond do
          is_list(stored) ->
            i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
            new_stored = if i >= 0 and i < length(stored) do
              List.replace_at(stored, i, val)
            else
              stored ++ List.duplicate(:undefined, max(0, i - length(stored))) ++ [val]
            end
            Process.put({:qb_obj, ref}, new_stored)
          is_map(stored) ->
            key = if is_integer(idx), do: Integer.to_string(idx), else: Kernel.to_string(idx)
            Process.put({:qb_obj, ref}, Map.put(stored, key, val))
          true -> :ok
        end
        {:obj, ref}
      _ -> obj
    end
    run(advance(frame), [idx, obj2 | rest], gas - 1)
  end

  # ── Closure variable refs (mutable) ──

  defp run({:make_var_ref, [idx]}, %Frame{locals: locals} = frame, stack, gas) do
    ref = make_ref()
    Process.put({:qb_cell, ref}, elem(locals, idx))
    run(advance(frame), [{:cell, ref} | stack], gas - 1)
  end

  defp run({:make_arg_ref, [idx]}, frame, stack, gas) do
    ref = make_ref()
    Process.put({:qb_cell, ref}, get_arg_value(idx))
    run(advance(frame), [{:cell, ref} | stack], gas - 1)
  end

  defp run({:make_loc_ref, [idx]}, %Frame{locals: locals} = frame, stack, gas) do
    ref = make_ref()
    Process.put({:qb_cell, ref}, elem(locals, idx))
    run(advance(frame), [{:cell, ref} | stack], gas - 1)
  end

  defp run({:get_var_ref_check, [idx]}, %Frame{var_refs: vrefs} = frame, stack, gas) do
    case elem(vrefs, idx) do
      :undefined -> throw({:error, {:uninitialized_var_ref, idx}})
      {:cell, _} = cell -> run(advance(frame), [read_cell(cell) | stack], gas - 1)
      val -> run(advance(frame), [val | stack], gas - 1)
    end
  end

  defp run({:put_var_ref_check, [idx]}, %Frame{var_refs: vrefs} = frame, [val | rest], gas) do
    case elem(vrefs, idx) do
      {:cell, ref} -> write_cell({:cell, ref}, val)
      _ -> :ok
    end
    run(advance(frame), rest, gas - 1)
  end

  defp run({:put_var_ref_check_init, [idx]}, %Frame{var_refs: vrefs} = frame, [val | rest], gas) do
    case elem(vrefs, idx) do
      {:cell, ref} -> write_cell({:cell, ref}, val)
      _ -> :ok
    end
    run(advance(frame), rest, gas - 1)
  end

  defp run({:get_ref_value, []}, frame, [ref | rest], gas) do
    run(advance(frame), [read_cell(ref) | rest], gas - 1)
  end

  defp run({:put_ref_value, []}, frame, [val, ref | rest], gas) do
    write_cell(ref, val)
    run(advance(frame), [val | rest], gas - 1)
  end

  # ── gosub/ret (finally blocks) ──

  defp run({:gosub, [target]}, %Frame{pc: pc} = frame, stack, gas) do
    run(jump(frame, target), [{:return_addr, pc + 1} | stack], gas - 1)
  end

  defp run({:ret, []}, frame, [{:return_addr, ret_pc} | rest], gas) do
    run(jump(frame, ret_pc), rest, gas - 1)
  end

  # ── eval (stub) ──

  defp run({:eval, [_argc]}, frame, [_val | rest], gas) do
    run(advance(frame), [:undefined | rest], gas - 1)
  end

  # ── Iterators ──

  defp run({:for_of_start, []}, frame, [obj | rest], gas) do
    items = case obj do
      list when is_list(list) -> list
      {:obj, ref} ->
        stored = Process.get({:qb_obj, ref}, [])
        if is_list(stored), do: stored, else: []
      _ -> []
    end
    run(advance(frame), [{:for_of_iterator, items, 0} | rest], gas - 1)
  end

  defp run({:for_of_next, [_idx]}, frame, [{:for_of_iterator, items, pos} | rest], gas) when is_list(items) do
    if pos < length(items) do
      run(advance(frame), [false, Enum.at(items, pos), {:for_of_iterator, items, pos + 1} | rest], gas - 1)
    else
      run(advance(frame), [true, :undefined, {:for_of_iterator, items, pos} | rest], gas - 1)
    end
  end

  defp run({:for_of_next, [_idx]}, frame, [iter | rest], gas) do
    run(advance(frame), [true, :undefined, iter | rest], gas - 1)
  end

  defp run({:iterator_next, []}, frame, [{:for_of_iterator, items, pos} | rest], gas) when is_list(items) do
    if pos < length(items) do
      run(advance(frame), [false, Enum.at(items, pos), {:for_of_iterator, items, pos + 1} | rest], gas - 1)
    else
      run(advance(frame), [true, :undefined, {:for_of_iterator, items, pos} | rest], gas - 1)
    end
  end

  defp run({:iterator_next, []}, frame, [iter | rest], gas) do
    run(advance(frame), [true, :undefined, iter | rest], gas - 1)
  end

  defp run({:iterator_close, []}, frame, [_iter | rest], gas), do: run(advance(frame), rest, gas - 1)
  defp run({:iterator_check_object, []}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)
  defp run({:iterator_call, []}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)
  defp run({:iterator_get_value_done, []}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)

  # ── Misc stubs ──

  defp run({:put_arg, [idx]}, frame, [val | rest], gas) do
    arg_buf = Process.get(:qb_arg_buf, {})
    padded = Tuple.to_list(arg_buf)
    padded = if idx < length(padded), do: padded, else: padded ++ List.duplicate(:undefined, idx + 1 - length(padded))
    Process.put(:qb_arg_buf, List.to_tuple(List.replace_at(padded, idx, val)))
    run(advance(frame), rest, gas - 1)
  end

  defp run({:set_home_object, []}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)
  defp run({:set_proto, []}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)

  defp run({:special_object, [type]}, frame, stack, gas) do
    val = case type do
      1 ->
        arg_buf = Process.get(:qb_arg_buf, {})
        args_list = Tuple.to_list(arg_buf)
        ref = System.unique_integer([:positive])
        Process.put({:qb_obj, ref}, args_list)
        {:obj, ref}
      2 -> Process.get(:qb_current_func, :undefined)
      3 -> Process.get(:qb_current_func, :undefined)
      _ -> :undefined
    end
    run(advance(frame), [val | stack], gas - 1)
  end

  defp run({:rest, [start_idx]}, frame, stack, gas) do
    arg_buf = Process.get(:qb_arg_buf, {})
    rest_args = if start_idx < tuple_size(arg_buf) do
      Tuple.to_list(arg_buf) |> Enum.drop(start_idx)
    else
      []
    end
    ref = System.unique_integer([:positive])
    Process.put({:qb_obj, ref}, rest_args)
    run(advance(frame), [{:obj, ref} | stack], gas - 1)
  end

  defp run({:typeof_is_function, [_atom_idx]}, frame, stack, gas), do: run(advance(frame), [false | stack], gas - 1)
  defp run({:typeof_is_undefined, [_atom_idx]}, frame, stack, gas), do: run(advance(frame), [false | stack], gas - 1)

  defp run({:throw_error, []}, _frame, [val | _], _gas), do: throw({:js_throw, val})
  defp run({:set_name_computed, []}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)

  defp run({:copy_data_properties, []}, frame, stack, gas), do: run(advance(frame), stack, gas - 1)

  defp run({:get_super, []}, frame, [func | rest], gas) do
    raw = case func do
      {:closure, _, %Bytecode.Function{} = f} -> f
      %Bytecode.Function{} = f -> f
      _ -> func
    end
    parent = Process.get({:qb_parent_ctor, :erlang.phash2(raw)})
    run(advance(frame), [(parent || :undefined) | rest], gas - 1)
  end

  defp run({:push_this, []}, frame, stack, gas) do
    run(advance(frame), [Process.get(:qb_this, :undefined) | stack], gas - 1)
  end

  defp run({:private_symbol, []}, frame, stack, gas), do: run(advance(frame), [:undefined | stack], gas - 1)

  # ── Argument mutation ──

  defp run({:set_arg, [idx]}, frame, [val | rest], gas) do
    arg_buf = Process.get(:qb_arg_buf, {})
    list = Tuple.to_list(arg_buf)
    padded = if idx < length(list), do: list, else: list ++ List.duplicate(:undefined, idx + 1 - length(list))
    Process.put(:qb_arg_buf, List.to_tuple(List.replace_at(padded, idx, val)))
    run(advance(frame), [val | rest], gas - 1)
  end

  defp run({:set_arg0, []}, frame, [val | rest], gas) do
    Process.put(:qb_arg_buf, put_elem(Process.get(:qb_arg_buf, {}), 0, val))
    run(advance(frame), [val | rest], gas - 1)
  end

  defp run({:set_arg1, []}, frame, [val | rest], gas) do
    arg_buf = Process.get(:qb_arg_buf, {})
    if tuple_size(arg_buf) > 1, do: Process.put(:qb_arg_buf, put_elem(arg_buf, 1, val))
    run(advance(frame), [val | rest], gas - 1)
  end

  defp run({:set_arg2, []}, frame, [val | rest], gas) do
    arg_buf = Process.get(:qb_arg_buf, {})
    if tuple_size(arg_buf) > 2, do: Process.put(:qb_arg_buf, put_elem(arg_buf, 2, val))
    run(advance(frame), [val | rest], gas - 1)
  end

  defp run({:set_arg3, []}, frame, [val | rest], gas) do
    arg_buf = Process.get(:qb_arg_buf, {})
    if tuple_size(arg_buf) > 3, do: Process.put(:qb_arg_buf, put_elem(arg_buf, 3, val))
    run(advance(frame), [val | rest], gas - 1)
  end

  # ── Array element access (2-element push) ──

  defp run({:get_array_el2, []}, frame, [idx, obj | rest], gas) do
    run(advance(frame), [Runtime.get_property(obj, idx), obj | rest], gas - 1)
  end

  # ── Spread/rest via apply ──

  defp run({:apply, [_magic]}, frame, [arg_array, this_obj, fun | rest], gas) do
    args = case arg_array do
      list when is_list(list) -> list
      {:obj, ref} ->
        stored = Process.get({:qb_obj, ref}, [])
        if is_list(stored), do: stored, else: []
      _ -> []
    end
    result = case fun do
      %Bytecode.Function{} = f -> invoke_function(f, args, gas)
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, args, gas)
      {:builtin, _name, cb} when is_function(cb, 2) -> cb.(args, this_obj)
      {:builtin, _name, cb} when is_function(cb, 3) -> cb.(args, this_obj, self())
      {:builtin, _name, cb} when is_function(cb, 1) -> cb.(args)
      f when is_function(f) -> apply(f, [this_obj | args])
      _ -> throw({:error, {:not_a_function, fun}})
    end
    run(advance(frame), [result | rest], gas - 1)
  end

  # ── Object spread (copy_data_properties with mask) ──

  defp run({:copy_data_properties, [mask]}, frame, stack, gas) do
    target_idx = mask &&& 3
    source_idx = Bitwise.bsr(mask, 2) &&& 7
    target = Enum.at(stack, target_idx)
    source = Enum.at(stack, source_idx)
    src_props = case source do
      {:obj, ref} -> Process.get({:qb_obj, ref}, %{})
      map when is_map(map) -> map
      _ -> %{}
    end
    case target do
      {:obj, ref} ->
        existing = Process.get({:qb_obj, ref}, %{})
        Process.put({:qb_obj, ref}, Map.merge(existing, src_props))
      _ -> :ok
    end
    run(advance(frame), stack, gas - 1)
  end

  # ── Class definitions ──

  defp run({:define_class, [_atom_idx, _flags]}, frame, [ctor, parent_ctor | rest], gas) do
    proto_ref = make_ref()
    proto_map = case ctor do
      %Bytecode.Function{} = f -> %{"constructor" => {:closure, %{}, f}}
      closure -> %{"constructor" => closure}
    end
    parent_proto = Process.get({:qb_class_proto, :erlang.phash2(parent_ctor)})
    proto_map = if parent_proto, do: Map.put(proto_map, "__proto__", parent_proto), else: proto_map
    Process.put({:qb_obj, proto_ref}, proto_map)
    proto = {:obj, proto_ref}
    Process.put({:qb_class_proto, :erlang.phash2(ctor)}, proto)
    if parent_ctor != :undefined do
      Process.put({:qb_parent_ctor, :erlang.phash2(ctor)}, parent_ctor)
    end
    run(advance(frame), [proto, ctor | rest], gas - 1)
  end

  defp run({:define_method, [atom_idx, _flags]}, frame, [method_closure, target | rest], gas) do
    name = resolve_atom(atom_idx)
    case target do
      {:obj, ref} ->
        existing = Process.get({:qb_obj, ref}, %{})
        if is_map(existing), do: Process.put({:qb_obj, ref}, Map.put(existing, name, method_closure))
      _ -> :ok
    end
    run(advance(frame), [target | rest], gas - 1)
  end

  defp run({:define_method_computed, [_flags]}, frame, [method_closure, target, field_name | rest], gas) do
    case target do
      {:obj, ref} ->
        proto = Process.get({:qb_obj, ref}, %{})
        Process.put({:qb_obj, ref}, Map.put(proto, field_name, method_closure))
      _ -> :ok
    end
    run(advance(frame), rest, gas - 1)
  end

  # ── Catch-all for unimplemented opcodes ──

  defp run({name, args}, _frame, _stack, _gas) do
    throw({:error, {:unimplemented_opcode, name, args}})
  end

  # ── Tail calls ──

  defp tail_call(stack, argc, gas) do
    {args, [fun | _rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)
    result = case fun do
      %Bytecode.Function{} = f -> invoke_function(f, rev_args, gas)
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, rev_args, gas)
      {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
      f when is_function(f) -> apply(f, rev_args)
      _ -> throw({:error, {:not_a_function, fun}})
    end
    throw({:js_return, result})
  end

  defp tail_call_method(stack, argc, gas) do
    {args, [fun, obj | _rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)
    prev_this = Process.get(:qb_this)
    Process.put(:qb_this, obj)
    result = try do
      case fun do
        %Bytecode.Function{} = f -> invoke_function(f, [obj | rev_args], gas)
        {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, [obj | rev_args], gas)
        {:builtin, _name, cb} when is_function(cb, 2) -> cb.(rev_args, obj)
        {:builtin, _name, cb} when is_function(cb, 3) -> cb.(rev_args, obj, :no_interp)
        {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
        f when is_function(f) -> apply(f, [obj | rev_args])
        _ -> throw({:error, {:not_a_function, fun}})
      end
    after
      if prev_this, do: Process.put(:qb_this, prev_this), else: Process.delete(:qb_this)
    end
    throw({:js_return, result})
  end

  # ── Closure construction ──

  defp build_closure(%Bytecode.Function{} = fun, locals, vrefs) do
    arg_buf = Process.get(:qb_arg_buf, {})
    l2v = Process.get(:qb_local_to_vref, %{})
    captured = for cv <- fun.closure_vars do
      cell = case Map.get(l2v, cv.var_idx) do
        nil ->
          val = cond do
            cv.var_idx < tuple_size(arg_buf) -> elem(arg_buf, cv.var_idx)
            cv.var_idx < tuple_size(locals) -> elem(locals, cv.var_idx)
            true -> :undefined
          end
          ref = make_ref()
          Process.put({:qb_cell, ref}, val)
          {:cell, ref}
        vref_idx ->
          case elem(vrefs, vref_idx) do
            {:cell, _} = existing -> existing
            _ ->
              val = elem(locals, cv.var_idx)
              ref = make_ref()
              Process.put({:qb_cell, ref}, val)
              {:cell, ref}
          end
      end
      {cv.var_idx, cell}
    end
    {:closure, Map.new(captured), fun}
  end
  defp build_closure(other, _locals, _vrefs), do: other

  # ── Function calls ──

  defp call_function(frame, stack, argc, gas) do
    {args, [fun | rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)
    result = case fun do
      %Bytecode.Function{} = f -> invoke_function(f, rev_args, gas)
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, rev_args, gas)
      {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
      f when is_function(f) -> apply(f, rev_args)
      _ -> throw({:error, {:not_a_function, fun}})
    end
    run(advance(frame), [result | rest], gas - 1)
  end

  defp call_method(frame, stack, argc, gas) do
    {args, [fun, obj | rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)
    prev_this = Process.get(:qb_this)
    Process.put(:qb_this, obj)
    result = try do
      case fun do
        %Bytecode.Function{} = f -> invoke_function(f, [obj | rev_args], gas)
        {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, [obj | rev_args], gas)
        {:builtin, _name, cb} when is_function(cb, 2) -> cb.(rev_args, obj)
        {:builtin, _name, cb} when is_function(cb, 3) -> cb.(rev_args, obj, :no_interp)
        {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
        f when is_function(f) -> apply(f, [obj | rev_args])
        _ -> throw({:error, {:not_a_function, fun}})
      end
    after
      if prev_this, do: Process.put(:qb_this, prev_this), else: Process.delete(:qb_this)
    end
    run(advance(frame), [result | rest], gas - 1)
  end

  def invoke_function(%Bytecode.Function{} = fun, args, gas) do
    do_invoke(fun, args, [], gas)
  end

  def invoke_closure({:closure, captured, %Bytecode.Function{} = fun}, args, gas) do
    var_refs = for cv <- fun.closure_vars do
      Map.get(captured, cv.var_idx, :undefined)
    end
    do_invoke(fun, args, var_refs, gas)
  end

  defp do_invoke(%Bytecode.Function{} = fun, args, var_refs, gas) do
    prev_func = Process.get(:qb_current_func)
    prev_local_map = Process.get(:qb_local_to_vref)
    prev_catch = Process.get(:qb_catch_stack)
    self_ref = if length(var_refs) > 0 or length(fun.closure_vars) > 0 do
      {:closure, %{}, fun}
    else
      fun
    end
    Process.put(:qb_current_func, self_ref)

    try do
      case Decoder.decode(fun.byte_code) do
        {:ok, instructions} ->
          insns = List.to_tuple(instructions)
          locals = :erlang.make_tuple(max(fun.arg_count + fun.var_count, 1), :undefined)
          {locals, var_refs_tuple} = setup_captured_locals(fun, locals, var_refs, args)

          frame = %Frame{
            pc: 0,
            locals: locals,
            constants: fun.constants,
            var_refs: var_refs_tuple,
            stack_size: fun.stack_size,
            instructions: insns
          }

          prev_args = Process.get(:qb_arg_buf)
          Process.put(:qb_arg_buf, List.to_tuple(args))

          try do
            run(frame, [], gas)
          catch
            {:js_return, val} -> val
            {:js_throw, val} -> throw({:js_throw, val})
            {:error, _} = err -> throw(err)
          after
            if prev_args, do: Process.put(:qb_arg_buf, prev_args), else: Process.delete(:qb_arg_buf)
          end

        {:error, _} = err ->
          throw(err)
      end
    after
      if prev_func, do: Process.put(:qb_current_func, prev_func), else: Process.delete(:qb_current_func)
      if prev_local_map, do: Process.put(:qb_local_to_vref, prev_local_map), else: Process.delete(:qb_local_to_vref)
      if prev_catch, do: Process.put(:qb_catch_stack, prev_catch), else: Process.delete(:qb_catch_stack)
    end
  end
end
