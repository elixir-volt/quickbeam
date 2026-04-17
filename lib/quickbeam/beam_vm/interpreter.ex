defmodule QuickBEAM.BeamVM.Interpreter do
  @moduledoc """
  Executes decoded QuickJS bytecode via multi-clause function dispatch.

  The interpreter pre-decodes bytecode into instruction tuples for O(1) indexed
  access, then runs a tail-recursive dispatch loop with one `defp run/5` clause
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
  alias __MODULE__.{Frame, Ctx}

  alias QuickBEAM.BeamVM.Heap
  alias __MODULE__.{Values, Objects, Closures, Scope}
  import Bitwise, only: [bnot: 1, &&&: 2]

  @default_gas 1_000_000_000

  @spec eval(Bytecode.Function.t()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun), do: eval(fun, [], %{})

  @spec eval(Bytecode.Function.t(), [term()], map()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun, args, opts), do: eval(fun, args, opts, {})

  @spec eval(Bytecode.Function.t(), [term()], map(), tuple()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun, args, opts, atoms) do
    gas = Map.get(opts, :gas, @default_gas)

    ctx = %Ctx{atoms: atoms, globals: Runtime.global_bindings()}
    Heap.put_ctx(ctx)

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
          {:ok, run(frame, args, gas, ctx)}
        catch
          {:js_throw, val} -> {:error, {:js_throw, val}}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Invoke a bytecode function or closure from external code."
  def invoke(%Bytecode.Function{} = fun, args, gas), do: invoke_function(fun, args, gas, active_ctx())
  def invoke({:closure, _, %Bytecode.Function{}} = c, args, gas), do: invoke_closure(c, args, gas, active_ctx())

  defp active_ctx, do: Heap.get_ctx() || %Ctx{}

  defp catch_js_throw(frame, rest, gas, ctx, fun) do
    try do
      result = fun.()
      run(advance(frame), [result | rest], gas - 1, ctx)
    catch
      {:js_throw, val} ->
        case ctx.catch_stack do
          [{target, saved_stack} | rest_catch] ->
            run(jump(frame, target), [val | saved_stack], gas - 1, %{ctx | catch_stack: rest_catch})
          [] ->
            throw({:js_throw, val})
        end
    end
  end

  # ── Helpers ──

  defp advance(%Frame{pc: pc} = f), do: %{f | pc: pc + 1}
  defp jump(%Frame{} = f, target), do: %{f | pc: target}
  defp put_local(%Frame{locals: locals} = f, idx, val), do: %{f | locals: put_elem(locals, idx, val)}


  defp make_error_obj(message, name) do
    ref = make_ref()
    Heap.put_obj(ref, %{"message" => message, "name" => name})
    {:obj, ref}
  end

  defp check_prototype_chain(_, :undefined), do: false
  defp check_prototype_chain(_, nil), do: false
  defp check_prototype_chain({:obj, ref}, target) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        case Map.get(map, "__proto__") do
          ^target -> true
          nil -> false
          :undefined -> false
          proto -> check_prototype_chain(proto, target)
        end
      _ -> false
    end
  end
  defp check_prototype_chain(_, _), do: false

  # ── Main dispatch loop ──

  defp run(_frame, _stack, gas, _ctx) when gas <= 0 do
    throw({:error, {:out_of_gas, gas}})
  end

  defp run(%Frame{pc: pc, instructions: insns} = frame, stack, gas, ctx) do
    run(elem(insns, pc), frame, stack, gas, ctx)
  end

  # ── Push constants ──

  defp run({:push_i32, [val]}, frame, stack, gas, ctx), do: run(advance(frame), [val | stack], gas - 1, ctx)
  defp run({:push_i8, [val]}, frame, stack, gas, ctx), do: run(advance(frame), [val | stack], gas - 1, ctx)
  defp run({:push_i16, [val]}, frame, stack, gas, ctx), do: run(advance(frame), [val | stack], gas - 1, ctx)
  defp run({:push_minus1, _}, frame, stack, gas, ctx), do: run(advance(frame), [-1 | stack], gas - 1, ctx)
  defp run({:push_0, _}, frame, stack, gas, ctx), do: run(advance(frame), [0 | stack], gas - 1, ctx)
  defp run({:push_1, _}, frame, stack, gas, ctx), do: run(advance(frame), [1 | stack], gas - 1, ctx)
  defp run({:push_2, _}, frame, stack, gas, ctx), do: run(advance(frame), [2 | stack], gas - 1, ctx)
  defp run({:push_3, _}, frame, stack, gas, ctx), do: run(advance(frame), [3 | stack], gas - 1, ctx)
  defp run({:push_4, _}, frame, stack, gas, ctx), do: run(advance(frame), [4 | stack], gas - 1, ctx)
  defp run({:push_5, _}, frame, stack, gas, ctx), do: run(advance(frame), [5 | stack], gas - 1, ctx)
  defp run({:push_6, _}, frame, stack, gas, ctx), do: run(advance(frame), [6 | stack], gas - 1, ctx)
  defp run({:push_7, _}, frame, stack, gas, ctx), do: run(advance(frame), [7 | stack], gas - 1, ctx)

  defp run({op, [idx]}, %Frame{constants: cpool} = frame, stack, gas, ctx) when op in [:push_const, :push_const8] do
    run(advance(frame), [Scope.resolve_const(cpool, idx) | stack], gas - 1, ctx)
  end

  defp run({:push_atom_value, [atom_idx]}, frame, stack, gas, ctx) do
    run(advance(frame), [Scope.resolve_atom(ctx, atom_idx) | stack], gas - 1, ctx)
  end

  defp run({:undefined, []}, frame, stack, gas, ctx), do: run(advance(frame), [:undefined | stack], gas - 1, ctx)
  defp run({:null, []}, frame, stack, gas, ctx), do: run(advance(frame), [nil | stack], gas - 1, ctx)
  defp run({:push_false, []}, frame, stack, gas, ctx), do: run(advance(frame), [false | stack], gas - 1, ctx)
  defp run({:push_true, []}, frame, stack, gas, ctx), do: run(advance(frame), [true | stack], gas - 1, ctx)
  defp run({:push_empty_string, []}, frame, stack, gas, ctx), do: run(advance(frame), ["" | stack], gas - 1, ctx)
  defp run({:push_bigint_i32, [val]}, frame, stack, gas, ctx), do: run(advance(frame), [{:bigint, val} | stack], gas - 1, ctx)

  # ── Stack manipulation ──

  defp run({:drop, []}, frame, [_ | rest], gas, ctx), do: run(advance(frame), rest, gas - 1, ctx)
  defp run({:nip, []}, frame, [a, _b | rest], gas, ctx), do: run(advance(frame), [a | rest], gas - 1, ctx)
  defp run({:nip1, []}, frame, [a, b, _c | rest], gas, ctx), do: run(advance(frame), [a, b | rest], gas - 1, ctx)
  defp run({:dup, []}, frame, [a | _] = stack, gas, ctx), do: run(advance(frame), [a | stack], gas - 1, ctx)

  defp run({:dup1, []}, frame, [a, b | _] = stack, gas, ctx) do
    run(advance(frame), [a, b | stack], gas - 1, ctx)
  end

  defp run({:dup2, []}, frame, [a, b | _] = stack, gas, ctx) do
    run(advance(frame), [a, b, a, b | stack], gas - 1, ctx)
  end

  defp run({:dup3, []}, frame, [a, b, c | _] = stack, gas, ctx) do
    run(advance(frame), [a, b, c, a, b, c | stack], gas - 1, ctx)
  end

  defp run({:insert2, []}, frame, [a, b | rest], gas, ctx), do: run(advance(frame), [a, b, a | rest], gas - 1, ctx)
  defp run({:insert3, []}, frame, [a, b, c | rest], gas, ctx), do: run(advance(frame), [a, b, c, a | rest], gas - 1, ctx)
  defp run({:insert4, []}, frame, [a, b, c, d | rest], gas, ctx), do: run(advance(frame), [a, b, c, d, a | rest], gas - 1, ctx)
  defp run({:perm3, []}, frame, [a, b, c | rest], gas, ctx), do: run(advance(frame), [c, a, b | rest], gas - 1, ctx)
  defp run({:perm4, []}, frame, [a, b, c, d | rest], gas, ctx), do: run(advance(frame), [d, a, b, c | rest], gas - 1, ctx)
  defp run({:perm5, []}, frame, [a, b, c, d, e | rest], gas, ctx), do: run(advance(frame), [e, a, b, c, d | rest], gas - 1, ctx)
  defp run({:swap, []}, frame, [a, b | rest], gas, ctx), do: run(advance(frame), [b, a | rest], gas - 1, ctx)
  defp run({:swap2, []}, frame, [a, b, c, d | rest], gas, ctx), do: run(advance(frame), [c, d, a, b | rest], gas - 1, ctx)
  defp run({:rot3l, []}, frame, [a, b, c | rest], gas, ctx), do: run(advance(frame), [b, c, a | rest], gas - 1, ctx)
  defp run({:rot3r, []}, frame, [a, b, c | rest], gas, ctx), do: run(advance(frame), [c, a, b | rest], gas - 1, ctx)
  defp run({:rot4l, []}, frame, [a, b, c, d | rest], gas, ctx), do: run(advance(frame), [b, c, d, a | rest], gas - 1, ctx)
  defp run({:rot5l, []}, frame, [a, b, c, d, e | rest], gas, ctx), do: run(advance(frame), [b, c, d, e, a | rest], gas - 1, ctx)

  # ── Args ──

  defp run({:get_arg, [idx]}, frame, stack, gas, ctx), do: run(advance(frame), [Scope.get_arg_value(ctx, idx) | stack], gas - 1, ctx)
  defp run({:get_arg0, []}, frame, stack, gas, ctx), do: run(advance(frame), [Scope.get_arg_value(ctx, 0) | stack], gas - 1, ctx)
  defp run({:get_arg1, []}, frame, stack, gas, ctx), do: run(advance(frame), [Scope.get_arg_value(ctx, 1) | stack], gas - 1, ctx)
  defp run({:get_arg2, []}, frame, stack, gas, ctx), do: run(advance(frame), [Scope.get_arg_value(ctx, 2) | stack], gas - 1, ctx)
  defp run({:get_arg3, []}, frame, stack, gas, ctx), do: run(advance(frame), [Scope.get_arg_value(ctx, 3) | stack], gas - 1, ctx)

  # ── Locals ──

  defp run({:get_loc, [idx]}, %Frame{locals: locals, var_refs: vrefs, local_to_vref: l2v} = frame, stack, gas, ctx) do
    run(advance(frame), [Closures.read_captured_local(l2v, idx, locals, vrefs) | stack], gas - 1, ctx)
  end

  defp run({:put_loc, [idx]}, %Frame{locals: locals, var_refs: vrefs, local_to_vref: l2v} = frame, [val | rest], gas, ctx) do
    Closures.write_captured_local(l2v, idx, val, locals, vrefs)
    run(advance(put_local(frame, idx, val)), rest, gas - 1, ctx)
  end

  defp run({:set_loc, [idx]}, %Frame{locals: locals, var_refs: vrefs, local_to_vref: l2v} = frame, [val | rest], gas, ctx) do
    Closures.write_captured_local(l2v, idx, val, locals, vrefs)
    run(advance(put_local(frame, idx, val)), [val | rest], gas - 1, ctx)
  end

  defp run({:set_loc_uninitialized, [idx]}, frame, stack, gas, ctx) do
    run(advance(put_local(frame, idx, :undefined)), stack, gas - 1, ctx)
  end

  defp run({:get_loc_check, [idx]}, %Frame{locals: locals} = frame, stack, gas, ctx) do
    val = elem(locals, idx)
    if val == :undefined, do: throw({:error, {:uninitialized_local, idx}})
    run(advance(frame), [val | stack], gas - 1, ctx)
  end

  defp run({:put_loc_check, [idx]}, frame, [val | rest], gas, ctx) do
    if val == :undefined, do: throw({:error, {:uninitialized_local, idx}})
    run(advance(put_local(frame, idx, val)), rest, gas - 1, ctx)
  end

  defp run({:put_loc_check_init, [idx]}, frame, [val | rest], gas, ctx) do
    run(advance(put_local(frame, idx, val)), rest, gas - 1, ctx)
  end

  defp run({:get_loc0_loc1, []}, %Frame{locals: locals} = frame, stack, gas, ctx) do
    run(advance(frame), [elem(locals, 1), elem(locals, 0) | stack], gas - 1, ctx)
  end

  # ── Variable references (closures) ──

  defp run({:get_var_ref, [idx]}, %Frame{var_refs: vrefs} = frame, stack, gas, ctx) do
    val = case elem(vrefs, idx) do
      {:cell, _} = cell -> Closures.read_cell(cell)
      other -> other
    end
    run(advance(frame), [val | stack], gas - 1, ctx)
  end

  defp run({:put_var_ref, [idx]}, %Frame{var_refs: vrefs} = frame, [val | rest], gas, ctx) do
    case elem(vrefs, idx) do
      {:cell, ref} -> Closures.write_cell({:cell, ref}, val)
      _ -> :ok
    end
    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:set_var_ref, [idx]}, %Frame{var_refs: vrefs} = frame, [val | rest], gas, ctx) do
    case elem(vrefs, idx) do
      {:cell, ref} -> Closures.write_cell({:cell, ref}, val)
      _ -> :ok
    end
    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  defp run({:close_loc, [_idx]}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)

  # ── Control flow ──

  defp run({op, [target]}, frame, [val | rest], gas, ctx) when op in [:if_false, :if_false8] do
    if Values.falsy?(val), do: run(jump(frame, target), rest, gas - 1, ctx), else: run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({op, [target]}, frame, [val | rest], gas, ctx) when op in [:if_true, :if_true8] do
    if Values.truthy?(val), do: run(jump(frame, target), rest, gas - 1, ctx), else: run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({op, [target]}, frame, stack, gas, ctx) when op in [:goto, :goto8, :goto16] do
    run(jump(frame, target), stack, gas - 1, ctx)
  end

  defp run({:return, []}, _frame, [val | _], _gas, _ctx), do: val

  defp run({:return_undef, []}, _frame, _stack, _gas, _ctx), do: :undefined

  # ── Arithmetic ──

  defp run({:add, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.add(a, b) | rest], gas - 1, ctx)
  defp run({:sub, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.sub(a, b) | rest], gas - 1, ctx)
  defp run({:mul, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.mul(a, b) | rest], gas - 1, ctx)
  defp run({:div, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.div(a, b) | rest], gas - 1, ctx)
  defp run({:mod, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.mod(a, b) | rest], gas - 1, ctx)
  defp run({:pow, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.pow(a, b) | rest], gas - 1, ctx)

  # ── Bitwise ──

  defp run({:band, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.band(a, b) | rest], gas - 1, ctx)
  defp run({:bor, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.bor(a, b) | rest], gas - 1, ctx)
  defp run({:bxor, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.bxor(a, b) | rest], gas - 1, ctx)
  defp run({:shl, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.shl(a, b) | rest], gas - 1, ctx)
  defp run({:sar, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.sar(a, b) | rest], gas - 1, ctx)
  defp run({:shr, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.shr(a, b) | rest], gas - 1, ctx)

  # ── Comparison ──

  defp run({:lt, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.lt(a, b) | rest], gas - 1, ctx)
  defp run({:lte, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.lte(a, b) | rest], gas - 1, ctx)
  defp run({:gt, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.gt(a, b) | rest], gas - 1, ctx)
  defp run({:gte, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.gte(a, b) | rest], gas - 1, ctx)
  defp run({:eq, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.eq(a, b) | rest], gas - 1, ctx)
  defp run({:neq, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.neq(a, b) | rest], gas - 1, ctx)
  defp run({:strict_eq, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [Values.strict_eq(a, b) | rest], gas - 1, ctx)
  defp run({:strict_neq, []}, frame, [b, a | rest], gas, ctx), do: run(advance(frame), [not Values.strict_eq(a, b) | rest], gas - 1, ctx)

  # ── Unary ──

  defp run({:neg, []}, frame, [a | rest], gas, ctx), do: run(advance(frame), [Values.neg(a) | rest], gas - 1, ctx)
  defp run({:plus, []}, frame, [a | rest], gas, ctx), do: run(advance(frame), [Values.to_number(a) | rest], gas - 1, ctx)
  defp run({:inc, []}, frame, [a | rest], gas, ctx), do: run(advance(frame), [Values.add(a, 1) | rest], gas - 1, ctx)
  defp run({:dec, []}, frame, [a | rest], gas, ctx), do: run(advance(frame), [Values.sub(a, 1) | rest], gas - 1, ctx)
  defp run({:post_inc, []}, frame, [a | rest], gas, ctx), do: run(advance(frame), [Values.add(a, 1), a | rest], gas - 1, ctx)
  defp run({:post_dec, []}, frame, [a | rest], gas, ctx), do: run(advance(frame), [Values.sub(a, 1), a | rest], gas - 1, ctx)

  defp run({:inc_loc, [idx]}, %Frame{locals: locals, var_refs: vrefs, local_to_vref: l2v} = frame, stack, gas, ctx) do
    new_val = Values.add(elem(locals, idx), 1)
    Closures.write_captured_local(l2v, idx, new_val, locals, vrefs)
    run(advance(put_local(frame, idx, new_val)), stack, gas - 1, ctx)
  end

  defp run({:dec_loc, [idx]}, %Frame{locals: locals, var_refs: vrefs, local_to_vref: l2v} = frame, stack, gas, ctx) do
    new_val = Values.sub(elem(locals, idx), 1)
    Closures.write_captured_local(l2v, idx, new_val, locals, vrefs)
    run(advance(put_local(frame, idx, new_val)), stack, gas - 1, ctx)
  end

  defp run({:add_loc, [idx]}, %Frame{locals: locals, var_refs: vrefs, local_to_vref: l2v} = frame, [val | rest], gas, ctx) do
    new_val = Values.add(elem(locals, idx), val)
    Closures.write_captured_local(l2v, idx, new_val, locals, vrefs)
    run(advance(put_local(frame, idx, new_val)), rest, gas - 1, ctx)
  end

  defp run({:not, []}, frame, [a | rest], gas, ctx), do: run(advance(frame), [bnot(Values.to_int32(a)) | rest], gas - 1, ctx)
  defp run({:lnot, []}, frame, [a | rest], gas, ctx), do: run(advance(frame), [not Values.truthy?(a) | rest], gas - 1, ctx)
  defp run({:typeof, []}, frame, [a | rest], gas, ctx), do: run(advance(frame), [Values.typeof(a) | rest], gas - 1, ctx)

  # ── Function creation / calls ──

  defp run({op, [idx]}, %Frame{constants: cpool, locals: locals, var_refs: vrefs, local_to_vref: l2v} = frame, stack, gas, ctx) when op in [:fclosure, :fclosure8] do
    fun = Scope.resolve_const(cpool, idx)
    closure = build_closure(fun, locals, vrefs, l2v, ctx)
    run(advance(frame), [closure | stack], gas - 1, ctx)
  end

  defp run({:call, [argc]}, frame, stack, gas, ctx), do: call_function(frame, stack, argc, gas, ctx)
  defp run({:tail_call, [argc]}, _frame, stack, gas, ctx), do: tail_call(stack, argc, gas, ctx)
  defp run({:call_method, [argc]}, frame, stack, gas, ctx), do: call_method(frame, stack, argc, gas, ctx)
  defp run({:tail_call_method, [argc]}, _frame, stack, gas, ctx), do: tail_call_method(stack, argc, gas, ctx)

  # ── Objects ──

  defp run({:object, []}, frame, stack, gas, ctx) do
    ref = make_ref()
    Heap.put_obj(ref, %{})
    run(advance(frame), [{:obj, ref} | stack], gas - 1, ctx)
  end

  defp run({:get_field, [atom_idx]}, frame, [obj | _rest], gas, ctx) when obj == nil or obj == :undefined do
    prop = Scope.resolve_atom(ctx, atom_idx)
    nullish = if obj == nil, do: "null", else: "undefined"
    error = make_error_obj("Cannot read properties of #{nullish} (reading '#{prop}')", "TypeError")
    case ctx.catch_stack do
      [{target, saved_stack} | rest_catch] ->
        run(jump(frame, target), [error | saved_stack], gas - 1, %{ctx | catch_stack: rest_catch})
      [] ->
        throw({:js_throw, error})
    end
  end

  defp run({:get_field, [atom_idx]}, frame, [obj | rest], gas, ctx) do
    run(advance(frame), [Runtime.get_property(obj, Scope.resolve_atom(ctx, atom_idx)) | rest], gas - 1, ctx)
  end

  defp run({:put_field, [atom_idx]}, frame, [val, obj | rest], gas, ctx) do
    Objects.put(obj, Scope.resolve_atom(ctx, atom_idx), val)
    run(advance(frame), [obj | rest], gas - 1, ctx)
  end

  defp run({:define_field, [atom_idx]}, frame, [val, obj | rest], gas, ctx) do
    Objects.put(obj, Scope.resolve_atom(ctx, atom_idx), val)
    run(advance(frame), [obj | rest], gas - 1, ctx)
  end

  defp run({:get_array_el, []}, frame, [idx, obj | rest], gas, ctx) do
    run(advance(frame), [Objects.get_array_el(obj, idx) | rest], gas - 1, ctx)
  end

  defp run({:put_array_el, []}, frame, [val, idx, obj | rest], gas, ctx) do
    Objects.put_array_el(obj, idx, val)
    run(advance(frame), [obj | rest], gas - 1, ctx)
  end

  defp run({:get_length, []}, frame, [obj | rest], gas, ctx) do
    len = case obj do
      {:obj, ref} ->
        case Heap.get_obj(ref) do
          list when is_list(list) -> length(list)
          map when is_map(map) -> map_size(map)
          _ -> 0
        end
      list when is_list(list) -> length(list)
      s when is_binary(s) -> Runtime.js_string_length(s)
      _ -> :undefined
    end
    run(advance(frame), [len | rest], gas - 1, ctx)
  end

  defp run({:array_from, [argc]}, frame, stack, gas, ctx) do
    {elems, rest} = Enum.split(stack, argc)
    ref = System.unique_integer([:positive])
    Heap.put_obj(ref, Enum.reverse(elems))
    run(advance(frame), [{:obj, ref} | rest], gas - 1, ctx)
  end

  # ── Misc / no-op ──

  defp run({:nop, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)
  defp run({:to_object, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)
  defp run({:to_propkey, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)
  defp run({:to_propkey2, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)
  defp run({:check_ctor, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:check_ctor_return, []}, frame, [val | rest], gas, %Ctx{this: this} = ctx) do
    result = case val do
      {:obj, _} = obj -> obj
      _ -> this
    end
    run(advance(frame), [result | rest], gas - 1, ctx)
  end

  defp run({:set_name, [_atom_idx]}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:throw, []}, frame, [val | _], gas, %Ctx{catch_stack: catch_stack} = ctx) do
    case catch_stack do
      [{target, saved_stack} | rest_catch] ->
        run(jump(frame, target), [val | saved_stack], gas - 1, %{ctx | catch_stack: rest_catch})
      [] ->
        throw({:js_throw, val})
    end
  end

  defp run({:is_undefined, []}, frame, [a | rest], gas, ctx), do: run(advance(frame), [a == :undefined | rest], gas - 1, ctx)
  defp run({:is_null, []}, frame, [a | rest], gas, ctx), do: run(advance(frame), [a == nil | rest], gas - 1, ctx)
  defp run({:is_undefined_or_null, []}, frame, [a | rest], gas, ctx), do: run(advance(frame), [a == :undefined or a == nil | rest], gas - 1, ctx)
  defp run({:invalid, []}, _frame, _stack, _gas, _ctx), do: throw({:error, :invalid_opcode})

  defp run({:get_var_undef, [atom_idx]}, frame, stack, gas, ctx) do
    val = case Scope.resolve_global(ctx, atom_idx) do
      {:found, v} -> v
      :not_found -> :undefined
    end
    run(advance(frame), [val | stack], gas - 1, ctx)
  end

  defp run({:get_var, [atom_idx]}, frame, stack, gas, ctx) do
    case Scope.resolve_global(ctx, atom_idx) do
      {:found, val} ->
        run(advance(frame), [val | stack], gas - 1, ctx)
      :not_found ->
        error = make_error_obj("#{Scope.resolve_atom(ctx, atom_idx)} is not defined", "ReferenceError")
        case ctx.catch_stack do
          [{target, saved_stack} | rest_catch] ->
            run(jump(frame, target), [error | saved_stack], gas - 1, %{ctx | catch_stack: rest_catch})
          [] ->
            throw({:js_throw, error})
        end
    end
  end

  defp run({:put_var, [atom_idx]}, frame, [val | rest], gas, ctx) do
    run(advance(frame), rest, gas - 1, Scope.set_global(ctx, atom_idx, val))
  end

  defp run({:put_var_init, [atom_idx]}, frame, [val | rest], gas, ctx) do
    run(advance(frame), rest, gas - 1, Scope.set_global(ctx, atom_idx, val))
  end

  defp run({:define_var, [atom_idx, _scope]}, frame, [val | rest], gas, ctx) do
    Heap.put_var(Scope.resolve_atom(ctx, atom_idx), val)
    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:check_define_var, [atom_idx, _scope]}, frame, stack, gas, ctx) do
    Heap.delete_var(Scope.resolve_atom(ctx, atom_idx))
    run(advance(frame), stack, gas - 1, ctx)
  end

  defp run({:get_field2, [atom_idx]}, frame, [obj | _rest], gas, ctx) when obj == nil or obj == :undefined do
    prop = Scope.resolve_atom(ctx, atom_idx)
    nullish = if obj == nil, do: "null", else: "undefined"
    error = make_error_obj("Cannot read properties of #{nullish} (reading '#{prop}')", "TypeError")
    case ctx.catch_stack do
      [{target, saved_stack} | rest_catch] ->
        run(jump(frame, target), [error | saved_stack], gas - 1, %{ctx | catch_stack: rest_catch})
      [] ->
        throw({:js_throw, error})
    end
  end

  defp run({:get_field2, [atom_idx]}, frame, [obj | rest], gas, ctx) do
    val = Runtime.get_property(obj, Scope.resolve_atom(ctx, atom_idx))
    run(advance(frame), [val, obj | rest], gas - 1, ctx)
  end

  # ── try/catch ──

  defp run({:catch, [target]}, frame, stack, gas, %Ctx{catch_stack: catch_stack} = ctx) do
    ctx = %{ctx | catch_stack: [{target, stack} | catch_stack]}
    run(advance(frame), [target | stack], gas - 1, ctx)
  end

  defp run({:nip_catch, []}, frame, [a, _catch_offset | rest], gas, %Ctx{catch_stack: [_ | rest_catch]} = ctx) do
    run(advance(frame), [a | rest], gas - 1, %{ctx | catch_stack: rest_catch})
  end

  # ── for-in ──

  defp run({:for_in_start, []}, frame, [obj | rest], gas, ctx) do
    keys = case obj do
      {:obj, ref} -> Map.keys(Heap.get_obj(ref, %{}))
      map when is_map(map) -> Map.keys(map)
      _ -> []
    end
    run(advance(frame), [{:for_in_iterator, keys} | rest], gas - 1, ctx)
  end

  defp run({:for_in_next, []}, frame, [{:for_in_iterator, [key | rest_keys]} | rest], gas, ctx) do
    run(advance(frame), [false, key, {:for_in_iterator, rest_keys} | rest], gas - 1, ctx)
  end

  defp run({:for_in_next, []}, frame, [iter | rest], gas, ctx) do
    run(advance(frame), [true, :undefined, iter | rest], gas - 1, ctx)
  end

  # ── new / constructor ──

  defp run({:call_constructor, [argc]}, frame, stack, gas, ctx) do
    {args, [_new_target, ctor | rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)

    raw_ctor = case ctor do
      {:closure, _, %Bytecode.Function{} = f} -> f
      other -> other
    end
    this_ref = make_ref()
    proto = Heap.get_class_proto(raw_ctor)
    init = if proto, do: %{"__proto__" => proto}, else: %{}
    Heap.put_obj(this_ref, init)
    this_obj = {:obj, this_ref}

    ctor_ctx = %{ctx | this: this_obj}

    result = case ctor do
      %Bytecode.Function{} = f ->
        do_invoke(f, rev_args, ctor_var_refs(f), gas, ctor_ctx)

      {:closure, captured, %Bytecode.Function{} = f} ->
        do_invoke(f, rev_args, ctor_var_refs(f, captured), gas, ctor_ctx)

      {:builtin, name, cb} when is_function(cb, 1) ->
        obj = cb.(rev_args)
        if name in ~w(Error TypeError RangeError SyntaxError ReferenceError URIError EvalError) do
          case obj do
            {:obj, ref} ->
              existing = Heap.get_obj(ref, %{})
              if is_map(existing) and not Map.has_key?(existing, "name") do
                Heap.put_obj(ref, Map.put(existing, "name", name))
              end
            _ -> :ok
          end
        end
        obj

      _ -> this_obj
    end

    result = case result do
      {:obj, _} = obj -> obj
      _ -> this_obj
    end

    case {result, Heap.get_class_proto(raw_ctor)} do
      {{:obj, rref}, {:obj, _} = proto2} ->
        rmap = Heap.get_obj(rref, %{})
        unless Map.has_key?(rmap, "__proto__") do
          Heap.put_obj(rref, Map.put(rmap, "__proto__", proto2))
        end
      _ -> :ok
    end

    run(advance(frame), [result | rest], gas - 1, ctx)
  end

  defp run({:init_ctor, []}, frame, stack, gas, %Ctx{arg_buf: arg_buf} = ctx) do
    raw = case ctx.current_func do
      {:closure, _, %Bytecode.Function{} = f} -> f
      %Bytecode.Function{} = f -> f
      other -> other
    end
    parent = Heap.get_parent_ctor(raw)
    args = Tuple.to_list(arg_buf)
    result = case parent do
      nil ->
        ctx.this
      %Bytecode.Function{} = f ->
        do_invoke(f, args, ctor_var_refs(f), gas, ctx)
      {:closure, captured, %Bytecode.Function{} = f} ->
        do_invoke(f, args, ctor_var_refs(f, captured), gas, ctx)
      {:builtin, _name, cb} when is_function(cb, 1) ->
        cb.(args)
      _ ->
        ctx.this
    end
    result = case result do
      {:obj, _} = obj -> obj
      _ -> ctx.this
    end
    run(advance(frame), [result | stack], gas - 1, %{ctx | this: result})
  end

  # ── instanceof ──

  defp run({:instanceof, []}, frame, [ctor, obj | rest], gas, ctx) do
    result = case obj do
      {:obj, _} ->
        ctor_proto = Runtime.get_property(ctor, "prototype")
        check_prototype_chain(obj, ctor_proto)
      _ -> false
    end
    run(advance(frame), [result | rest], gas - 1, ctx)
  end

  # ── delete ──

  defp run({:delete, []}, frame, [key, obj | rest], gas, ctx) do
    case obj do
      {:obj, ref} ->
        map = Heap.get_obj(ref, %{})
        if is_map(map), do: Heap.put_obj(ref, Map.delete(map, key))
      _ -> :ok
    end
    run(advance(frame), [true | rest], gas - 1, ctx)
  end

  defp run({:delete_var, [_atom_idx]}, frame, stack, gas, ctx), do: run(advance(frame), [true | stack], gas - 1, ctx)

  # ── in operator ──

  defp run({:in, []}, frame, [obj, key | rest], gas, ctx) do
    run(advance(frame), [Objects.has_property(obj, key) | rest], gas - 1, ctx)
  end

  # ── regexp literal ──

  defp run({:regexp, []}, frame, [pattern, flags | rest], gas, ctx) do
    run(advance(frame), [{:regexp, pattern, flags} | rest], gas - 1, ctx)
  end

  # ── spread / array construction ──

  defp run({:append, []}, frame, [obj, idx, arr | rest], gas, ctx) do
    src_list = case obj do
      list when is_list(list) -> list
      {:obj, ref} -> Heap.get_obj(ref, [])
      _ -> []
    end
    arr_list = case arr do
      list when is_list(list) -> list
      {:obj, ref} -> Heap.get_obj(ref, [])
      _ -> []
    end
    merged = arr_list ++ src_list
    new_idx = (if is_integer(idx), do: idx, else: Runtime.to_int(idx)) + length(src_list)
    merged_obj = case arr do
      {:obj, ref} ->
        Heap.put_obj(ref, merged)
        {:obj, ref}
      _ -> merged
    end
    run(advance(frame), [new_idx, merged_obj | rest], gas - 1, ctx)
  end

  defp run({:define_array_el, []}, frame, [val, idx, obj | rest], gas, ctx) do
    obj2 = case obj do
      list when is_list(list) ->
        i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
        Objects.list_set_at(list, i, val)
      {:obj, ref} ->
        stored = Heap.get_obj(ref, [])
        cond do
          is_list(stored) ->
            i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
            Heap.put_obj(ref, Objects.list_set_at(stored, i, val))
          is_map(stored) ->
            key = if is_integer(idx), do: Integer.to_string(idx), else: Kernel.to_string(idx)
            Heap.put_obj(ref, Map.put(stored, key, val))
          true -> :ok
        end
        {:obj, ref}
      _ -> obj
    end
    run(advance(frame), [idx, obj2 | rest], gas - 1, ctx)
  end

  # ── Closure variable refs (mutable) ──

  defp run({:make_var_ref, [idx]}, %Frame{locals: locals} = frame, stack, gas, ctx) do
    ref = make_ref()
    Heap.put_cell(ref, elem(locals, idx))
    run(advance(frame), [{:cell, ref} | stack], gas - 1, ctx)
  end

  defp run({:make_arg_ref, [idx]}, frame, stack, gas, ctx) do
    ref = make_ref()
    Heap.put_cell(ref, Scope.get_arg_value(ctx, idx))
    run(advance(frame), [{:cell, ref} | stack], gas - 1, ctx)
  end

  defp run({:make_loc_ref, [idx]}, %Frame{locals: locals} = frame, stack, gas, ctx) do
    ref = make_ref()
    Heap.put_cell(ref, elem(locals, idx))
    run(advance(frame), [{:cell, ref} | stack], gas - 1, ctx)
  end

  defp run({:get_var_ref_check, [idx]}, %Frame{var_refs: vrefs} = frame, stack, gas, ctx) do
    case elem(vrefs, idx) do
      :undefined -> throw({:error, {:uninitialized_var_ref, idx}})
      {:cell, _} = cell -> run(advance(frame), [Closures.read_cell(cell) | stack], gas - 1, ctx)
      val -> run(advance(frame), [val | stack], gas - 1, ctx)
    end
  end

  defp run({:put_var_ref_check, [idx]}, %Frame{var_refs: vrefs} = frame, [val | rest], gas, ctx) do
    case elem(vrefs, idx) do
      {:cell, ref} -> Closures.write_cell({:cell, ref}, val)
      _ -> :ok
    end
    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:put_var_ref_check_init, [idx]}, %Frame{var_refs: vrefs} = frame, [val | rest], gas, ctx) do
    case elem(vrefs, idx) do
      {:cell, ref} -> Closures.write_cell({:cell, ref}, val)
      _ -> :ok
    end
    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:get_ref_value, []}, frame, [ref | rest], gas, ctx) do
    run(advance(frame), [Closures.read_cell(ref) | rest], gas - 1, ctx)
  end

  defp run({:put_ref_value, []}, frame, [val, ref | rest], gas, ctx) do
    Closures.write_cell(ref, val)
    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  # ── gosub/ret (finally blocks) ──

  defp run({:gosub, [target]}, %Frame{pc: pc} = frame, stack, gas, ctx) do
    run(jump(frame, target), [{:return_addr, pc + 1} | stack], gas - 1, ctx)
  end

  defp run({:ret, []}, frame, [{:return_addr, ret_pc} | rest], gas, ctx) do
    run(jump(frame, ret_pc), rest, gas - 1, ctx)
  end

  # ── eval (stub) ──

  defp run({:eval, [_argc]}, frame, [_val | rest], gas, ctx) do
    run(advance(frame), [:undefined | rest], gas - 1, ctx)
  end

  # ── Iterators ──

  defp run({:for_of_start, []}, frame, [obj | rest], gas, ctx) do
    items = case obj do
      list when is_list(list) -> list
      {:obj, ref} ->
        stored = Heap.get_obj(ref, [])
        if is_list(stored), do: stored, else: []
      s when is_binary(s) -> String.graphemes(s)
      _ -> []
    end
    run(advance(frame), [{:for_of_iterator, items, 0} | rest], gas - 1, ctx)
  end

  defp run({:for_of_next, [_idx]}, frame, [{:for_of_iterator, items, pos} | rest], gas, ctx) when is_list(items) do
    if pos < length(items) do
      run(advance(frame), [false, Enum.at(items, pos), {:for_of_iterator, items, pos + 1} | rest], gas - 1, ctx)
    else
      run(advance(frame), [true, :undefined, {:for_of_iterator, items, pos} | rest], gas - 1, ctx)
    end
  end

  defp run({:for_of_next, [_idx]}, frame, [iter | rest], gas, ctx) do
    run(advance(frame), [true, :undefined, iter | rest], gas - 1, ctx)
  end

  defp run({:iterator_next, []}, frame, [{:for_of_iterator, items, pos} | rest], gas, ctx) when is_list(items) do
    if pos < length(items) do
      run(advance(frame), [false, Enum.at(items, pos), {:for_of_iterator, items, pos + 1} | rest], gas - 1, ctx)
    else
      run(advance(frame), [true, :undefined, {:for_of_iterator, items, pos} | rest], gas - 1, ctx)
    end
  end

  defp run({:iterator_next, []}, frame, [iter | rest], gas, ctx) do
    run(advance(frame), [true, :undefined, iter | rest], gas - 1, ctx)
  end

  defp run({:iterator_close, []}, frame, [_iter | rest], gas, ctx), do: run(advance(frame), rest, gas - 1, ctx)
  defp run({:iterator_check_object, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)
  defp run({:iterator_call, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)
  defp run({:iterator_get_value_done, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)

  # ── Misc stubs ──

  defp run({:put_arg, [idx]}, frame, [val | rest], gas, %Ctx{arg_buf: arg_buf} = ctx) do
    padded = Tuple.to_list(arg_buf)
    padded = if idx < length(padded), do: padded, else: padded ++ List.duplicate(:undefined, idx + 1 - length(padded))
    ctx = %{ctx | arg_buf: List.to_tuple(List.replace_at(padded, idx, val))}
    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:set_home_object, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)
  defp run({:set_proto, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:special_object, [type]}, frame, stack, gas, %Ctx{arg_buf: arg_buf, current_func: current_func} = ctx) do
    val = case type do
      1 ->
        args_list = Tuple.to_list(arg_buf)
        ref = System.unique_integer([:positive])
        Heap.put_obj(ref, args_list)
        {:obj, ref}
      2 -> current_func
      3 -> current_func
      _ -> :undefined
    end
    run(advance(frame), [val | stack], gas - 1, ctx)
  end

  defp run({:rest, [start_idx]}, frame, stack, gas, %Ctx{arg_buf: arg_buf} = ctx) do
    rest_args = if start_idx < tuple_size(arg_buf) do
      Tuple.to_list(arg_buf) |> Enum.drop(start_idx)
    else
      []
    end
    ref = System.unique_integer([:positive])
    Heap.put_obj(ref, rest_args)
    run(advance(frame), [{:obj, ref} | stack], gas - 1, ctx)
  end

  defp run({:typeof_is_function, [_atom_idx]}, frame, stack, gas, ctx), do: run(advance(frame), [false | stack], gas - 1, ctx)
  defp run({:typeof_is_undefined, [_atom_idx]}, frame, stack, gas, ctx), do: run(advance(frame), [false | stack], gas - 1, ctx)

  defp run({:throw_error, []}, _frame, [val | _], _gas, _ctx), do: throw({:js_throw, val})
  defp run({:set_name_computed, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:copy_data_properties, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:get_super, []}, frame, [func | rest], gas, ctx) do
    raw = case func do
      {:closure, _, %Bytecode.Function{} = f} -> f
      %Bytecode.Function{} = f -> f
      _ -> func
    end
    parent = Heap.get_parent_ctor(raw)
    run(advance(frame), [(parent || :undefined) | rest], gas - 1, ctx)
  end

  defp run({:push_this, []}, frame, stack, gas, %Ctx{this: this} = ctx) do
    run(advance(frame), [this | stack], gas - 1, ctx)
  end

  defp run({:private_symbol, []}, frame, stack, gas, ctx), do: run(advance(frame), [:undefined | stack], gas - 1, ctx)

  # ── Argument mutation ──

  defp run({:set_arg, [idx]}, frame, [val | rest], gas, %Ctx{arg_buf: arg_buf} = ctx) do
    list = Tuple.to_list(arg_buf)
    padded = if idx < length(list), do: list, else: list ++ List.duplicate(:undefined, idx + 1 - length(list))
    ctx = %{ctx | arg_buf: List.to_tuple(List.replace_at(padded, idx, val))}
    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  defp run({:set_arg0, []}, frame, [val | rest], gas, %Ctx{arg_buf: arg_buf} = ctx) do
    run(advance(frame), [val | rest], gas - 1, %{ctx | arg_buf: put_elem(arg_buf, 0, val)})
  end

  defp run({:set_arg1, []}, frame, [val | rest], gas, %Ctx{arg_buf: arg_buf} = ctx) do
    ctx = if tuple_size(arg_buf) > 1, do: %{ctx | arg_buf: put_elem(arg_buf, 1, val)}, else: ctx
    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  defp run({:set_arg2, []}, frame, [val | rest], gas, %Ctx{arg_buf: arg_buf} = ctx) do
    ctx = if tuple_size(arg_buf) > 2, do: %{ctx | arg_buf: put_elem(arg_buf, 2, val)}, else: ctx
    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  defp run({:set_arg3, []}, frame, [val | rest], gas, %Ctx{arg_buf: arg_buf} = ctx) do
    ctx = if tuple_size(arg_buf) > 3, do: %{ctx | arg_buf: put_elem(arg_buf, 3, val)}, else: ctx
    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  # ── Array element access (2-element push) ──

  defp run({:get_array_el2, []}, frame, [idx, obj | rest], gas, ctx) do
    run(advance(frame), [Runtime.get_property(obj, idx), obj | rest], gas - 1, ctx)
  end

  # ── Spread/rest via apply ──

  defp run({:apply, [_magic]}, frame, [arg_array, this_obj, fun | rest], gas, ctx) do
    args = case arg_array do
      list when is_list(list) -> list
      {:obj, ref} ->
        stored = Heap.get_obj(ref, [])
        if is_list(stored), do: stored, else: []
      _ -> []
    end
    apply_ctx = %{ctx | this: this_obj}
    result = case fun do
      %Bytecode.Function{} = f -> invoke_function(f, args, gas, apply_ctx)
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, args, gas, apply_ctx)
      {:builtin, _name, cb} when is_function(cb, 2) -> cb.(args, this_obj)
      {:builtin, _name, cb} when is_function(cb, 3) -> cb.(args, this_obj, self())
      {:builtin, _name, cb} when is_function(cb, 1) -> cb.(args)
      f when is_function(f) -> apply(f, [this_obj | args])
      _ -> throw({:js_throw, make_error_obj("not a function", "TypeError")})
    end
    run(advance(frame), [result | rest], gas - 1, ctx)
  end

  # ── Object spread (copy_data_properties with mask) ──

  defp run({:copy_data_properties, [mask]}, frame, stack, gas, ctx) do
    target_idx = mask &&& 3
    source_idx = Bitwise.bsr(mask, 2) &&& 7
    target = Enum.at(stack, target_idx)
    source = Enum.at(stack, source_idx)
    src_props = case source do
      {:obj, ref} -> Heap.get_obj(ref, %{})
      map when is_map(map) -> map
      _ -> %{}
    end
    case target do
      {:obj, ref} ->
        existing = Heap.get_obj(ref, %{})
        Heap.put_obj(ref, Map.merge(existing, src_props))
      _ -> :ok
    end
    run(advance(frame), stack, gas - 1, ctx)
  end

  # ── Class definitions ──

  defp run({:define_class, [_atom_idx, _flags]}, %Frame{locals: locals, var_refs: vrefs, local_to_vref: l2v} = frame, [ctor, parent_ctor | rest], gas, ctx) do
    ctor_closure = case ctor do
      %Bytecode.Function{} = f -> build_closure(f, locals, vrefs, l2v, ctx)
      already_closure -> already_closure
    end
    raw = case ctor_closure do
      {:closure, _, %Bytecode.Function{} = f} -> f
      %Bytecode.Function{} = f -> f
      other -> other
    end
    proto_ref = make_ref()
    proto_map = %{"constructor" => ctor_closure}
    parent_proto = Heap.get_class_proto(parent_ctor)
    proto_map = if parent_proto, do: Map.put(proto_map, "__proto__", parent_proto), else: proto_map
    Heap.put_obj(proto_ref, proto_map)
    proto = {:obj, proto_ref}
    Heap.put_class_proto(raw, proto)
    Heap.put_ctor_static(ctor_closure, "prototype", proto)
    if parent_ctor != :undefined do
      Heap.put_parent_ctor(raw, parent_ctor)
    end
    run(advance(frame), [proto, ctor_closure | rest], gas - 1, ctx)
  end

  defp run({:define_method, [atom_idx, flags]}, frame, [method_closure, target | rest], gas, ctx) do
    name = Scope.resolve_atom(ctx, atom_idx)
    method_type = Bitwise.band(flags, 3)
    case method_type do
      1 -> Objects.put_getter(target, name, method_closure)
      2 -> Objects.put_setter(target, name, method_closure)
      _ -> Objects.put(target, name, method_closure)
    end
    run(advance(frame), [target | rest], gas - 1, ctx)
  end

  defp run({:define_method_computed, [_flags]}, frame, [method_closure, target, field_name | rest], gas, ctx) do
    case target do
      {:obj, ref} ->
        proto = Heap.get_obj(ref, %{})
        Heap.put_obj(ref, Map.put(proto, field_name, method_closure))
      _ -> :ok
    end
    run(advance(frame), rest, gas - 1, ctx)
  end

  # ── Catch-all for unimplemented opcodes ──

  defp run({name, args}, _frame, _stack, _gas, _ctx) do
    throw({:error, {:unimplemented_opcode, name, args}})
  end

  # ── Tail calls ──

  defp tail_call(stack, argc, gas, ctx) do
    {args, [fun | _rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)
    case fun do
      %Bytecode.Function{} = f -> invoke_function(f, rev_args, gas, ctx)
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, rev_args, gas, ctx)
      {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
      f when is_function(f) -> apply(f, rev_args)
      _ -> throw({:js_throw, make_error_obj("not a function", "TypeError")})
    end
  end

  defp tail_call_method(stack, argc, gas, ctx) do
    {args, [fun, obj | _rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)
    method_ctx = %{ctx | this: obj}
    case fun do
      %Bytecode.Function{} = f -> invoke_function(f, [obj | rev_args], gas, method_ctx)
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, [obj | rev_args], gas, method_ctx)
      {:builtin, _name, cb} when is_function(cb, 2) -> cb.(rev_args, obj)
      {:builtin, _name, cb} when is_function(cb, 3) -> cb.(rev_args, obj, :no_interp)
      {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
      f when is_function(f) -> apply(f, [obj | rev_args])
      _ -> throw({:js_throw, make_error_obj("not a function", "TypeError")})
    end
  end

  # ── Closure construction ──

  defp build_closure(%Bytecode.Function{} = fun, locals, vrefs, l2v, %Ctx{arg_buf: arg_buf}) do
    captured = for cv <- fun.closure_vars do
      cell = case Map.get(l2v, cv.var_idx) do
        nil ->
          val = cond do
            cv.var_idx < tuple_size(arg_buf) -> elem(arg_buf, cv.var_idx)
            cv.var_idx < tuple_size(locals) -> elem(locals, cv.var_idx)
            true -> :undefined
          end
          ref = make_ref()
          Heap.put_cell(ref, val)
          {:cell, ref}
        vref_idx ->
          case elem(vrefs, vref_idx) do
            {:cell, _} = existing -> existing
            _ ->
              val = elem(locals, cv.var_idx)
              ref = make_ref()
              Heap.put_cell(ref, val)
              {:cell, ref}
          end
      end
      {cv.var_idx, cell}
    end
    {:closure, Map.new(captured), fun}
  end
  defp build_closure(other, _locals, _vrefs, _l2v, _ctx), do: other

  defp ctor_var_refs(%Bytecode.Function{} = f, captured \\ %{}) do
    cell_ref = make_ref()
    Heap.put_cell(cell_ref, false)
    case f.closure_vars do
      [] -> [{:cell, cell_ref}]
      cvs -> Enum.map(cvs, &Map.get(captured, &1.var_idx, {:cell, cell_ref}))
    end
  end

  # ── Function calls ──

  defp call_function(frame, stack, argc, gas, ctx) do
    {args, [fun | rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)
    catch_js_throw(frame, rest, gas, ctx, fn ->
      case fun do
        %Bytecode.Function{} = f -> invoke_function(f, rev_args, gas, ctx)
        {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, rev_args, gas, ctx)
        {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
        f when is_function(f) -> apply(f, rev_args)
        _ -> throw({:js_throw, make_error_obj("not a function", "TypeError")})
      end
    end)
  end

  defp call_method(frame, stack, argc, gas, ctx) do
    {args, [fun, obj | rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)
    method_ctx = %{ctx | this: obj}
    invoke_args = [obj | rev_args]
    catch_js_throw(frame, rest, gas, ctx, fn ->
      case fun do
        %Bytecode.Function{} = f -> invoke_function(f, invoke_args, gas, method_ctx)
        {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, invoke_args, gas, method_ctx)
        {:builtin, _name, cb} when is_function(cb, 2) -> cb.(rev_args, obj)
        {:builtin, _name, cb} when is_function(cb, 3) -> cb.(rev_args, obj, :no_interp)
        {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
        f when is_function(f) -> apply(f, [obj | rev_args])
        _ -> throw({:js_throw, make_error_obj("not a function", "TypeError")})
      end
    end)
  end

  defp invoke_function(%Bytecode.Function{} = fun, args, gas, ctx) do
    do_invoke(fun, args, [], gas, ctx)
  end

  defp invoke_closure({:closure, captured, %Bytecode.Function{} = fun}, args, gas, ctx) do
    var_refs = for cv <- fun.closure_vars do
      Map.get(captured, cv.var_idx, :undefined)
    end
    do_invoke(fun, args, var_refs, gas, ctx)
  end

  defp do_invoke(%Bytecode.Function{} = fun, args, var_refs, gas, ctx) do
    self_ref = if var_refs != [] or fun.closure_vars != [] do
      {:closure, %{}, fun}
    else
      fun
    end

    case Decoder.decode(fun.byte_code) do
      {:ok, instructions} ->
        insns = List.to_tuple(instructions)
        locals = :erlang.make_tuple(max(fun.arg_count + fun.var_count, 1), :undefined)
        {locals, var_refs_tuple, l2v} = Closures.setup_captured_locals(fun, locals, var_refs, args)

        frame = %Frame{
          pc: 0,
          locals: locals,
          constants: fun.constants,
          var_refs: var_refs_tuple,
          stack_size: fun.stack_size,
          instructions: insns,
          local_to_vref: l2v
        }

        inner_ctx = %{ctx |
          current_func: self_ref,
          arg_buf: List.to_tuple(args),
          catch_stack: []
        }
        Heap.put_ctx(inner_ctx)
        run(frame, [], gas, inner_ctx)

      {:error, _} = err ->
        throw(err)
    end
  end
end
