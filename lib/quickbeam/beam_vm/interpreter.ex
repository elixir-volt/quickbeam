defmodule QuickBEAM.BeamVM.Interpreter do
  @moduledoc """
  Executes decoded QuickJS bytecode using flat function argument dispatch.

  The interpreter pre-decodes bytecode into instruction tuples for O(1) indexed
  access, then runs a tail-recursive dispatch loop. One `defp` per opcode.

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

  alias QuickBEAM.BeamVM.{Bytecode, Decoder, Runtime, PredefinedAtoms}
  import Bitwise

  defmodule Error do
    defexception [:message, :stack]
  end

  defmodule Return do
    @moduledoc "Signal for function return"
    defstruct [:value]
  end

  defmodule Throw do
    @moduledoc "Signal for JS throw"
    defstruct [:value]
  end

  @default_gas 100_000_000

  @spec eval(Bytecode.Function.t()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun) do
    eval(fun, [], %{})
  end

  @spec eval(Bytecode.Function.t(), [term()], map()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun, args, opts) do
    eval(fun, args, opts, {})
  end

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

        # Build initial stack: push arguments
        stack = args
        # Frame: {pc, locals, constants, var_refs, stack_size, instructions}
        locals = :erlang.make_tuple(max(fun.arg_count + fun.var_count, 1), :undefined)
        frame = {0, locals, fun.constants, [], fun.stack_size, instructions}

        try do
          result = run(frame, stack, gas)
          {:ok, result}
        catch
          {:throw, %Throw{value: val}} -> {:error, {:js_throw, val}}
          {:return, %Return{value: val}} -> {:ok, val}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  # ── Main dispatch loop ──
  # Each iteration: fetch instruction at pc, dispatch to opcode handler,
  # recurse with updated state. Gas counter prevents infinite loops.

  defp run({_pc, _locals, _cpool, _vrefs, _ssz, _insns} = frame, stack, gas) when gas <= 0 do
    throw({:error, {:out_of_gas, gas}})
  end

  defp run({pc, locals, cpool, vrefs, ssz, insns} = frame, stack, gas) do
    next = {pc + 1, locals, cpool, vrefs, ssz, insns}
    case elem(insns, pc) do
      # ── Push constants ──
      {:push_i32, [val]} ->
        run(next, [val | stack], gas - 1)

      {:push_i8, [val]} ->
        run(next, [val | stack], gas - 1)

      {:push_i16, [val]} ->
        run(next, [val | stack], gas - 1)

      {:push_minus1, _} ->
        run(next, [-1 | stack], gas - 1)

      {:push_0, _} ->
        run(next, [0 | stack], gas - 1)

      {:push_1, _} ->
        run(next, [1 | stack], gas - 1)

      {:push_2, _} ->
        run(next, [2 | stack], gas - 1)

      {:push_3, _} ->
        run(next, [3 | stack], gas - 1)

      {:push_4, _} ->
        run(next, [4 | stack], gas - 1)

      {:push_5, _} ->
        run(next, [5 | stack], gas - 1)

      {:push_6, _} ->
        run(next, [6 | stack], gas - 1)

      {:push_7, _} ->
        run(next, [7 | stack], gas - 1)

      {:push_const, [idx]} ->
        val = resolve_const(cpool, idx)
        run(next, [val | stack], gas - 1)

      {:push_atom_value, [atom_idx]} ->
        val = resolve_atom(atom_idx)
        run(next, [val | stack], gas - 1)

      {:undefined, []} ->
        run(next, [:undefined | stack], gas - 1)

      {:null, []} ->
        run(next, [nil | stack], gas - 1)

      {:push_false, []} ->
        run(next, [false | stack], gas - 1)

      {:push_true, []} ->
        run(next, [true | stack], gas - 1)

      {:push_empty_string, []} ->
        run(next, ["" | stack], gas - 1)

      {:push_bigint_i32, [val]} ->
        run(next, [{:bigint, val} | stack], gas - 1)

      # ── Stack manipulation ──
      {:drop, []} ->
        [_ | rest] = stack
        run(next, rest, gas - 1)

      {:nip, []} ->
        [a, _b | rest] = stack
        run(next, [a | rest], gas - 1)

      {:nip1, []} ->
        [a, b, _c | rest] = stack
        run(next, [a, b | rest], gas - 1)

      {:dup, []} ->
        [a | _] = stack
        run(next, [a | stack], gas - 1)

      {:dup1, []} ->
        [a, b | _] = stack
        run(next, [a, b | stack], gas - 1)

      {:dup2, []} ->
        [a, b | _] = stack
        run(next, [a, b, a, b | stack], gas - 1)

      {:dup3, []} ->
        [a, b, c | _] = stack
        run(next, [a, b, c, a, b, c | stack], gas - 1)

      {:insert2, []} ->
        [a, b | rest] = stack
        run(next, [a, b, a | rest], gas - 1)

      {:insert3, []} ->
        [a, b, c | rest] = stack
        run(next, [a, b, c, a | rest], gas - 1)

      {:insert4, []} ->
        [a, b, c, d | rest] = stack
        run(next, [a, b, c, d, a | rest], gas - 1)

      {:perm3, []} ->
        [a, b, c | rest] = stack
        run(next, [c, a, b | rest], gas - 1)

      {:perm4, []} ->
        [a, b, c, d | rest] = stack
        run(next, [d, a, b, c | rest], gas - 1)

      {:perm5, []} ->
        [a, b, c, d, e | rest] = stack
        run(next, [e, a, b, c, d | rest], gas - 1)

      {:swap, []} ->
        [a, b | rest] = stack
        run(next, [b, a | rest], gas - 1)

      {:swap2, []} ->
        [a, b, c, d | rest] = stack
        run(next, [c, d, a, b | rest], gas - 1)

      {:rot3l, []} ->
        [a, b, c | rest] = stack
        run(next, [b, c, a | rest], gas - 1)

      {:rot3r, []} ->
        [a, b, c | rest] = stack
        run(next, [c, a, b | rest], gas - 1)

      {:rot4l, []} ->
        [a, b, c, d | rest] = stack
        run(next, [b, c, d, a | rest], gas - 1)

      {:rot5l, []} ->
        [a, b, c, d, e | rest] = stack
        run(next, [b, c, d, e, a | rest], gas - 1)

      # ── Args (separate from locals in QuickJS) ──
      {:get_arg, [idx]} ->
        val = get_arg_value(idx)
        run(next, [val | stack], gas - 1)

      {:get_arg0, []} ->
        run(next, [get_arg_value(0) | stack], gas - 1)

      {:get_arg1, []} ->
        run(next, [get_arg_value(1) | stack], gas - 1)

      {:get_arg2, []} ->
        run(next, [get_arg_value(2) | stack], gas - 1)

      {:get_arg3, []} ->
        run(next, [get_arg_value(3) | stack], gas - 1)

      # ── Locals ──
      {:get_loc, [idx]} ->
        val = elem(locals, idx)
        run(next, [val | stack], gas - 1)

      {:put_loc, [idx]} ->
        [val | rest] = stack
        run({pc + 1, put_elem(locals, idx, val), cpool, vrefs, ssz, insns}, rest, gas - 1)

      {:set_loc, [idx]} ->
        [val | rest] = stack
        run({pc + 1, put_elem(locals, idx, val), cpool, vrefs, ssz, insns}, [val | rest], gas - 1)

      {:set_loc_uninitialized, [idx]} ->
        run({pc + 1, put_elem(locals, idx, :undefined), cpool, vrefs, ssz, insns}, stack, gas - 1)

      {:get_loc_check, [idx]} ->
        val = elem(locals, idx)
        if val == :undefined, do: throw({:error, {:uninitialized_local, idx}})
        run(next, [val | stack], gas - 1)

      {:put_loc_check, [idx]} ->
        [val | rest] = stack
        if val == :undefined, do: throw({:error, {:uninitialized_local, idx}})
        run({pc + 1, put_elem(locals, idx, val), cpool, vrefs, ssz, insns}, rest, gas - 1)

      {:put_loc_check_init, [idx]} ->
        [val | rest] = stack
        run({pc + 1, put_elem(locals, idx, val), cpool, vrefs, ssz, insns}, rest, gas - 1)

      {:get_loc0_loc1, []} ->
        run(next, [elem(locals, 0), elem(locals, 1) | stack], gas - 1)

      # ── Arguments ──
      {:get_arg, [idx]} ->
        val = elem(locals, idx)
        run(next, [val | stack], gas - 1)

      {:put_arg, [idx]} ->
        [val | rest] = stack
        run({pc + 1, put_elem(locals, idx, val), cpool, vrefs, ssz, insns}, rest, gas - 1)

      {:set_arg, [idx]} ->
        [val | rest] = stack
        run({pc + 1, put_elem(locals, idx, val), cpool, vrefs, ssz, insns}, [val | rest], gas - 1)

      # ── Variable references (closures) ──
      {:get_var_ref, [idx]} ->
        val = if idx < length(vrefs), do: Enum.at(vrefs, idx), else: :undefined
        run(next, [val | stack], gas - 1)

      {:put_var_ref, [idx]} ->
        [val | rest] = stack
        run(next, rest, gas - 1)

      {:set_var_ref, [idx]} ->
        [val | rest] = stack
        run(next, [val | rest], gas - 1)

      {:close_loc, [_idx]} ->
        # Capture local variable into a closure cell
        run(next, stack, gas - 1)

      # ── Control flow ──
      {:if_false, [target]} ->
        [val | rest] = stack
        if js_falsy(val) do
          run({target, locals, cpool, vrefs, ssz, insns}, rest, gas - 1)
        else
          run(next, rest, gas - 1)
        end

      {:if_false8, [target]} ->
        [val | rest] = stack
        if js_falsy(val) do
          run({target, locals, cpool, vrefs, ssz, insns}, rest, gas - 1)
        else
          run(next, rest, gas - 1)
        end

      {:if_true, [target]} ->
        [val | rest] = stack
        if js_truthy(val) do
          run({target, locals, cpool, vrefs, ssz, insns}, rest, gas - 1)
        else
          run(next, rest, gas - 1)
        end

      {:if_true8, [target]} ->
        [val | rest] = stack
        if js_truthy(val) do
          run({target, locals, cpool, vrefs, ssz, insns}, rest, gas - 1)
        else
          run(next, rest, gas - 1)
        end

      {:goto, [target]} ->
        run({target, locals, cpool, vrefs, ssz, insns}, stack, gas - 1)

      {:goto8, [target]} ->
        run({target, locals, cpool, vrefs, ssz, insns}, stack, gas - 1)

      {:goto16, [target]} ->
        run({target, locals, cpool, vrefs, ssz, insns}, stack, gas - 1)

      {:return, []} ->
        [val | _] = stack
        throw({:return, %Return{value: val}})

      {:return_undef, []} ->
        throw({:return, %Return{value: :undefined}})

      # ── Arithmetic ──
      {:add, []} ->
        [b, a | rest] = stack
        run(next, [js_add(a, b) | rest], gas - 1)

      {:sub, []} ->
        [b, a | rest] = stack
        run(next, [js_sub(a, b) | rest], gas - 1)

      {:mul, []} ->
        [b, a | rest] = stack
        run(next, [js_mul(a, b) | rest], gas - 1)

      {:div, []} ->
        [b, a | rest] = stack
        run(next, [js_div(a, b) | rest], gas - 1)

      {:mod, []} ->
        [b, a | rest] = stack
        run(next, [js_mod(a, b) | rest], gas - 1)

      {:pow, []} ->
        [b, a | rest] = stack
        run(next, [js_pow(a, b) | rest], gas - 1)

      # ── Bitwise ──
      {:band, []} ->
        [b, a | rest] = stack
        run(next, [js_band(a, b) | rest], gas - 1)

      {:bor, []} ->
        [b, a | rest] = stack
        run(next, [js_bor(a, b) | rest], gas - 1)

      {:bxor, []} ->
        [b, a | rest] = stack
        run(next, [js_bxor(a, b) | rest], gas - 1)

      {:shl, []} ->
        [b, a | rest] = stack
        run(next, [js_shl(a, b) | rest], gas - 1)

      {:sar, []} ->
        [b, a | rest] = stack
        run(next, [js_sar(a, b) | rest], gas - 1)

      {:shr, []} ->
        [b, a | rest] = stack
        run(next, [js_shr(a, b) | rest], gas - 1)

      # ── Comparison ──
      {:lt, []} ->
        [b, a | rest] = stack
        run(next, [js_lt(a, b) | rest], gas - 1)

      {:lte, []} ->
        [b, a | rest] = stack
        run(next, [js_lte(a, b) | rest], gas - 1)

      {:gt, []} ->
        [b, a | rest] = stack
        run(next, [js_gt(a, b) | rest], gas - 1)

      {:gte, []} ->
        [b, a | rest] = stack
        run(next, [js_gte(a, b) | rest], gas - 1)

      {:eq, []} ->
        [b, a | rest] = stack
        run(next, [js_eq(a, b) | rest], gas - 1)

      {:neq, []} ->
        [b, a | rest] = stack
        run(next, [js_neq(a, b) | rest], gas - 1)

      {:strict_eq, []} ->
        [b, a | rest] = stack
        run(next, [a === b | rest], gas - 1)

      {:strict_neq, []} ->
        [b, a | rest] = stack
        run(next, [a !== b | rest], gas - 1)

      # ── Unary ──
      {:neg, []} ->
        [a | rest] = stack
        run(next, [js_neg(a) | rest], gas - 1)

      {:plus, []} ->
        [a | rest] = stack
        run(next, [js_to_number(a) | rest], gas - 1)

      {:inc, []} ->
        [a | rest] = stack
        run(next, [js_add(a, 1) | rest], gas - 1)

      {:dec, []} ->
        [a | rest] = stack
        run(next, [js_sub(a, 1) | rest], gas - 1)

      {:post_inc, []} ->
        [a | rest] = stack
        run(next, [js_add(a, 1), a | rest], gas - 1)

      {:post_dec, []} ->
        [a | rest] = stack
        run(next, [js_sub(a, 1), a | rest], gas - 1)

      {:inc_loc, [idx]} ->
        val = elem(locals, idx)
        frame = {pc + 1, put_elem(locals, idx, js_add(val, 1)), cpool, vrefs, ssz, insns}
        run(next, stack, gas - 1)

      {:dec_loc, [idx]} ->
        val = elem(locals, idx)
        frame = {pc + 1, put_elem(locals, idx, js_sub(val, 1)), cpool, vrefs, ssz, insns}
        run(next, stack, gas - 1)

      {:add_loc, [idx]} ->
        [val | rest] = stack
        frame = {pc + 1, put_elem(locals, idx, js_add(elem(locals, idx), val)), cpool, vrefs, ssz, insns}
        run(next, rest, gas - 1)

      {:not, []} ->
        [a | rest] = stack
        run(next, [bsl(js_to_int32(a), 0) &&& (-1) | rest], gas - 1)

      {:lnot, []} ->
        [a | rest] = stack
        run(next, [not js_truthy(a) | rest], gas - 1)

      {:typeof, []} ->
        [a | rest] = stack
        run(next, [js_typeof(a) | rest], gas - 1)

      # ── Function creation / calls ──
      {:fclosure, [idx]} ->
        fun = resolve_const(cpool, idx)
        closure = build_closure(fun, locals, vrefs)
        run(next, [closure | stack], gas - 1)

      {:fclosure8, [idx]} ->
        fun = resolve_const(cpool, idx)
        closure = build_closure(fun, locals, vrefs)
        run(next, [closure | stack], gas - 1)

      {:push_const8, [idx]} ->
        val = resolve_const(cpool, idx)
        run(next, [val | stack], gas - 1)

      {:call, [argc]} ->
        call_function(frame, stack, argc, gas)

      {:tail_call, [argc]} ->
        tail_call(stack, argc, gas)

      {:call_method, [argc]} ->
        call_method(frame, stack, argc, gas)

      {:tail_call_method, [argc]} ->
        tail_call_method(stack, argc, gas)

      # ── Objects ──
      {:object, []} ->
        ref = make_ref()
        Process.put({:qb_obj, ref}, %{})
        run(next, [{:obj, ref} | stack], gas - 1)

      {:get_field, [atom_idx]} ->
        [obj | rest] = stack
        key = resolve_atom(atom_idx)
        val = Runtime.get_property(obj, key)
        run(next, [val | rest], gas - 1)

      {:put_field, [atom_idx]} ->
        [val, obj | rest] = stack
        key = resolve_atom(atom_idx)
        obj_put(obj, key, val)
        run(next, [obj | rest], gas - 1)

      {:define_field, [atom_idx]} ->
        [val, obj | rest] = stack
        key = resolve_atom(atom_idx)
        obj_put(obj, key, val)
        run(next, [obj | rest], gas - 1)

      {:get_array_el, []} ->
        [idx, obj | rest] = stack
        val = get_array_el(obj, idx)
        run(next, [val | rest], gas - 1)

      {:put_array_el, []} ->
        [val, idx, obj | rest] = stack
        # Simplified — real impl needs mutation
        run(next, rest, gas - 1)

      {:get_length, []} ->
        [obj | rest] = stack
        len = case obj do
          {:obj, ref} -> map_size(Process.get({:qb_obj, ref}, %{}))
          list when is_list(list) -> length(list)
          s when is_binary(s) -> String.length(s)
          _ -> :undefined
        end
        run(next, [len | rest], gas - 1)

      {:array_from, [argc]} ->
        {elems, rest} = Enum.split(stack, argc)
        run(next, [Enum.reverse(elems) | rest], gas - 1)

      # ── Misc ──
      {:nop, []} ->
        run(next, stack, gas - 1)

      {:to_object, []} ->
        run(next, stack, gas - 1)

      {:to_propkey, []} ->
        run(next, stack, gas - 1)

      {:to_propkey2, []} ->
        run(next, stack, gas - 1)

      {:check_ctor, []} ->
        run(next, stack, gas - 1)

      {:check_ctor_return, []} ->
        run(next, stack, gas - 1)

      {:set_name, [_atom_idx]} ->
        run(next, stack, gas - 1)

      {:throw, []} ->
        [val | _] = stack
        throw({:throw, %Throw{value: val}})

      {:is_undefined, []} ->
        [a | rest] = stack
        run(next, [a == :undefined | rest], gas - 1)

      {:is_null, []} ->
        [a | rest] = stack
        run(next, [a == nil | rest], gas - 1)

      {:is_undefined_or_null, []} ->
        [a | rest] = stack
        run(next, [a == :undefined or a == nil | rest], gas - 1)

      {:invalid, []} ->
        throw({:error, :invalid_opcode})

      {:get_var_undef, [atom_idx]} ->
        val = resolve_global(atom_idx)
        run(next, [val | stack], gas - 1)

      {:get_var, [atom_idx]} ->
        val = resolve_global(atom_idx)
        run(next, [val | stack], gas - 1)

      {:put_var, [_atom_idx]} ->
        [_val | rest] = stack
        run(next, rest, gas - 1)

      {:put_var_init, [_atom_idx]} ->
        [_val | rest] = stack
        run(next, rest, gas - 1)

      # ── Variable declarations (var/let/const in function scope) ──
      {:define_var, [atom_idx]} ->
        [val | rest] = stack
        name = resolve_atom(atom_idx)
        Process.put({:qb_var, name}, val)
        run(next, rest, gas - 1)

      {:check_define_var, [atom_idx]} ->
        name = resolve_atom(atom_idx)
        Process.delete({:qb_var, name})
        run(next, stack, gas - 1)

      # ── Computed property access ──
      {:get_field2, []} ->
        [key, obj | rest] = stack
        val = Runtime.get_property(obj, key)
        run(next, [val | rest], gas - 1)

      # ── try/catch ──
      {:catch, [target]} ->
        run(next, stack, gas - 1)

      {:nip_catch, []} ->
        [a, _b | rest] = stack
        run(next, [a | rest], gas - 1)

      # ── for-in ──
      {:for_in_start, []} ->
        [_obj | rest] = stack
        # Return a simple iterator placeholder
        run(next, [{:for_in_iterator, []} | rest], gas - 1)

      {:for_in_next, []} ->
        [iter | rest] = stack
        case iter do
          {:for_in_iterator, []} ->
            run(next, [false, :undefined | rest], gas - 1)
          _ ->
            run(next, [false, :undefined | rest], gas - 1)
        end

      # ── new / constructor ──
      {:call_constructor, [argc]} ->
        {args, [ctor | rest]} = Enum.split(stack, argc)
        case ctor do
          %Bytecode.Function{} = f ->
            result = invoke_function(f, Enum.reverse(args), gas)
            run(next, [result | rest], gas - 1)
          _ ->
            ref = make_ref()
            Process.put({:qb_obj, ref}, %{})
            run(next, [{:obj, ref} | rest], gas - 1)
        end

      {:init_ctor, []} ->
        run(next, stack, gas - 1)

      # ── instanceof ──
      {:instanceof, []} ->
        [_ctor, _obj | rest] = stack
        run(next, [false | rest], gas - 1)

      # ── delete ──
      {:delete, []} ->
        [_key, _obj | rest] = stack
        run(next, [true | rest], gas - 1)

      {:delete_var, [_atom_idx]} ->
        run(next, [true | stack], gas - 1)

      # ── in operator ──
      {:in, []} ->
        [key, obj | rest] = stack
        result = has_property(obj, key)
        run(next, [result | rest], gas - 1)

      # ── regexp literal ──
      {:regexp, []} ->
        [_pattern, _flags | rest] = stack
        # Stub — return pattern string
        run(next, [{:regexp, _pattern, _flags} | rest], gas - 1)

      # ── spread / array construction ──
      {:append, []} ->
        [arr, obj | rest] = stack
        arr2 = case obj do
          list when is_list(list) -> arr ++ list
          _ -> arr
        end
        run(next, [arr2 | rest], gas - 1)

      {:define_array_el, []} ->
        [val, idx, obj | rest] = stack
        obj2 = case obj do
          list when is_list(list) -> List.insert_at(list, idx, val)
          _ -> obj
        end
        run(next, [obj2 | rest], gas - 1)

      # ── closure variable refs (mutable) ──
      {:make_var_ref, [idx]} ->
        # Create a mutable cell for closure var at idx
        ref = make_ref()
        val = elem(locals, idx)
        Process.put({:qb_cell, ref}, val)
        run(next, [{:cell, ref} | stack], gas - 1)

      {:make_arg_ref, [idx]} ->
        ref = make_ref()
        val = get_arg_value(idx)
        Process.put({:qb_cell, ref}, val)
        run(next, [{:cell, ref} | stack], gas - 1)

      {:make_loc_ref, [idx]} ->
        ref = make_ref()
        val = elem(locals, idx)
        Process.put({:qb_cell, ref}, val)
        run(next, [{:cell, ref} | stack], gas - 1)

      {:get_var_ref_check, [idx]} ->
        val = if idx < length(vrefs), do: Enum.at(vrefs, idx), else: :undefined
        if val == :undefined, do: throw({:error, {:uninitialized_var_ref, idx}})
        run(next, [val | stack], gas - 1)

      {:put_var_ref_check, [idx]} ->
        [val | rest] = stack
        # Mutable write — for now, just keep in vrefs list
        run(next, rest, gas - 1)

      {:put_var_ref_check_init, [idx]} ->
        [val | rest] = stack
        run(next, rest, gas - 1)

      {:get_ref_value, []} ->
        [ref | rest] = stack
        val = read_cell(ref)
        run(next, [val | rest], gas - 1)

      {:put_ref_value, []} ->
        [val, ref | rest] = stack
        write_cell(ref, val)
        run(next, [val | rest], gas - 1)

      # ── gosub/ret (used for finally blocks) ──
      {:gosub, [target]} ->
        run({target, locals, cpool, vrefs, ssz, insns}, [{:return_addr, pc + 1} | stack], gas - 1)

      {:ret, []} ->
        [{:return_addr, ret_pc} | rest] = stack
        run({ret_pc, locals, cpool, vrefs, ssz, insns}, rest, gas - 1)

      # ── eval (stub) ──
      {:eval, [_argc]} ->
        [_val | rest] = stack
        run(next, [:undefined | rest], gas - 1)

      # ── iterators (stubs for now) ──
      {:for_of_start, []} ->
        [_obj | rest] = stack
        run(next, [{:for_of_iterator, []} | rest], gas - 1)

      {:for_of_next, []} ->
        [_iter | rest] = stack
        run(next, [false, :undefined | rest], gas - 1)

      {:iterator_next, []} ->
        [_iter | rest] = stack
        run(next, [false, :undefined | rest], gas - 1)

      {:iterator_check_object, []} ->
        run(next, stack, gas - 1)

      {:iterator_call, []} ->
        run(next, stack, gas - 1)

      {:iterator_close, []} ->
        run(next, stack, gas - 1)

      {:iterator_get_value_done, []} ->
        run(next, stack, gas - 1)

      # ── Misc stubs for rarely-needed opcodes ──
      {:push_this, []} ->
        run(next, [:undefined | stack], gas - 1)

      {:set_home_object, []} ->
        run(next, stack, gas - 1)

      {:set_proto, []} ->
        run(next, stack, gas - 1)

      {:special_object, [type]} ->
        val = case type do
          2 -> Process.get(:qb_current_func, :undefined)
          _ -> :undefined
        end
        run(next, [val | stack], gas - 1)

      {:rest, [_argc]} ->
        run(next, [[] | stack], gas - 1)

      {:typeof_is_function, [_atom_idx]} ->
        run(next, [false | stack], gas - 1)

      {:typeof_is_undefined, [_atom_idx]} ->
        run(next, [false | stack], gas - 1)

      {:throw_error, []} ->
        [val | _] = stack
        throw({:throw, %Throw{value: val}})

      {:set_name_computed, []} ->
        run(next, stack, gas - 1)

      {:copy_data_properties, []} ->
        run(next, stack, gas - 1)

      {:private_symbol, []} ->
        run(next, [:undefined | stack], gas - 1)

      {name, args} ->
        throw({:error, {:unimplemented_opcode, name, args}})
    end
  end

  defp tail_call(stack, argc, gas) do
    {args, [fun | _rest]} = Enum.split(stack, argc)
    result = case fun do
      %Bytecode.Function{} = f -> invoke_function(f, Enum.reverse(args), gas)
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, Enum.reverse(args), gas)
      _ -> throw({:error, {:not_a_function, fun}})
    end
    throw({:return, %Return{value: result}})
  end

  defp tail_call_method(stack, argc, gas) do
    {args, [fun, _obj | _rest]} = Enum.split(stack, argc)
    result = case fun do
      %Bytecode.Function{} = f -> invoke_function(f, Enum.reverse(args), gas)
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, Enum.reverse(args), gas)
      _ -> throw({:error, {:not_a_function, fun}})
    end
    throw({:return, %Return{value: result}})
  end

  # ── Closure construction ──

  defp build_closure(%Bytecode.Function{} = fun, locals, _vrefs) do
    arg_buf = Process.get(:qb_arg_buf, {})
    captured = for cv <- fun.closure_vars do
      val = cond do
        cv.var_idx < tuple_size(arg_buf) -> elem(arg_buf, cv.var_idx)
        cv.var_idx < tuple_size(locals) -> elem(locals, cv.var_idx)
        true -> :undefined
      end
      {cv.var_idx, val}
    end
    {:closure, Map.new(captured), fun}
  end
  defp build_closure(other, _locals, _vrefs), do: other

  # ── Function calls ──

  defp call_function({_pc, locals, cpool, vrefs, ssz, insns} = _frame, stack, argc, gas) do
    {args, [fun | rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)
    result = case fun do
      %Bytecode.Function{} = f -> invoke_function(f, rev_args, gas)
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, rev_args, gas)
      {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
      f when is_function(f) -> apply(f, rev_args)
      _ -> throw({:error, {:not_a_function, fun}})
    end
    run({_pc + 1, locals, cpool, vrefs, ssz, insns}, [result | rest], gas - 1)
  end

  defp call_method({_pc, locals, cpool, vrefs, ssz, insns} = _frame, stack, argc, gas) do
    {args, [fun, obj | rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)
    result = case fun do
      %Bytecode.Function{} = f -> invoke_function(f, [obj | rev_args], gas)
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, [obj | rev_args], gas)
      {:builtin, _name, cb} when is_function(cb, 2) -> cb.(rev_args, obj)
      {:builtin, _name, cb} when is_function(cb, 3) -> cb.(rev_args, obj, :no_interp)
      {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
      f when is_function(f) -> apply(f, [obj | rev_args])
      _ -> throw({:error, {:not_a_function, fun}})
    end
    run({_pc + 1, locals, cpool, vrefs, ssz, insns}, [result | rest], gas - 1)
  end

  defp invoke_function(%Bytecode.Function{} = fun, args, gas) do
    do_invoke(fun, args, [], gas)
  end

  defp invoke_closure({:closure, captured, %Bytecode.Function{} = fun}, args, gas) do
    # Build var_refs from captured values
    # The closure_vars list maps var_ref indices to parent local indices
    var_refs = for cv <- fun.closure_vars do
      Map.get(captured, cv.var_idx, :undefined)
    end
    do_invoke(fun, args, var_refs, gas)
  end

  defp do_invoke(%Bytecode.Function{} = fun, args, var_refs, gas) do
    # For named function self-reference via special_object(2)
    prev_func = Process.get(:qb_current_func)
    # If we have closure vars, store as closure; otherwise as plain function
    self_ref = if length(var_refs) > 0 or length(fun.closure_vars) > 0 do
      {:closure, %{}, fun}
    else
      fun
    end
    Process.put(:qb_current_func, self_ref)

    try do
      _result = case Decoder.decode(fun.byte_code) do
        {:ok, instructions} ->
          insns = List.to_tuple(instructions)
          locals = :erlang.make_tuple(max(fun.arg_count + fun.var_count, 1), :undefined)
          frame = {0, locals, fun.constants, var_refs, fun.stack_size, insns}
          prev_args = Process.get(:qb_arg_buf)
          Process.put(:qb_arg_buf, List.to_tuple(args))

          try do
            run(frame, [], div(gas, 2))
          catch
            {:return, %Return{value: val}} -> val
            {:throw, %Throw{value: val}} -> throw({:throw, %Throw{value: val}})
            {:error, _} = err -> throw(err)
          after
            if prev_args, do: Process.put(:qb_arg_buf, prev_args), else: Process.delete(:qb_arg_buf)
          end

        {:error, _} = err ->
          throw(err)
      end
    after
      if prev_func, do: Process.put(:qb_current_func, prev_func), else: Process.delete(:qb_current_func)
    end
  end

  # ── Constant pool resolution ──

  defp resolve_const(cpool, idx) when is_list(cpool) and idx < length(cpool) do
    Enum.at(cpool, idx)
  end
  defp resolve_const(_cpool, idx), do: {:const_ref, idx}

  # ── Field access ──

  defp get_field(obj, key) when is_map(obj), do: Map.get(obj, key, :undefined)
  defp get_field(obj, key) when is_list(obj) and is_integer(key), do: Enum.at(obj, key, :undefined)
  defp get_field(_, _), do: :undefined

  # ── Mutable object store ──

  defp obj_get({:obj, ref}, key) do
    case Process.get({:qb_obj, ref}) do
      nil -> :undefined
      map -> Map.get(map, key, :undefined)
    end
  end
  defp obj_get(obj, key) when is_map(obj), do: Map.get(obj, key, :undefined)
  defp obj_get(obj, key) when is_list(obj) and is_integer(key), do: Enum.at(obj, key, :undefined)
  defp obj_get(obj, "length") when is_list(obj), do: length(obj)
  defp obj_get(obj, "length") when is_binary(obj), do: String.length(obj)
  defp obj_get(_, _), do: :undefined

  defp obj_put({:obj, ref}, key, val) do
    map = Process.get({:qb_obj, ref}, %{})
    Process.put({:qb_obj, ref}, Map.put(map, key, val))
  end
  defp obj_put(_, _, _), do: :ok

  defp get_property({:obj, ref}, key), do: Map.get(Process.get({:qb_obj, ref}, %{}), key, :undefined)
  defp get_property(obj, key) when is_map(obj), do: Map.get(obj, key, :undefined)
  defp get_property(obj, key) when is_list(obj) and is_integer(key), do: Enum.at(obj, key, :undefined)
  defp get_property(obj, key) when is_binary(obj) and is_integer(key) and key >= 0, do: String.at(obj, key) || :undefined
  defp get_property(obj, "length") when is_list(obj), do: length(obj)
  defp get_property(obj, "length") when is_binary(obj), do: String.length(obj)
  defp get_property(_, _), do: :undefined

  defp has_property({:obj, ref}, key), do: Map.has_key?(Process.get({:qb_obj, ref}, %{}), key)
  defp has_property(obj, key) when is_map(obj), do: Map.has_key?(obj, key)
  defp has_property(obj, key) when is_list(obj) and is_integer(key), do: key >= 0 and key < length(obj)
  defp has_property(_, _), do: false

  defp get_array_el(obj, idx) when is_list(obj) and is_integer(idx), do: Enum.at(obj, idx, :undefined)
  defp get_array_el(_, _), do: :undefined

  # ── Mutable cells for closures ──

  defp read_cell({:cell, ref}), do: Process.get({:qb_cell, ref}, :undefined)
  defp read_cell(_), do: :undefined

  defp write_cell({:cell, ref}, val), do: Process.put({:qb_cell, ref}, val)
  defp write_cell(_, _), do: :ok

  # ── JS value operations ──

  defp js_truthy(nil), do: false
  defp js_truthy(:undefined), do: false
  defp js_truthy(false), do: false
  defp js_truthy(0), do: false
  defp js_truthy(0.0), do: false
  defp js_truthy(""), do: false
  defp js_truthy(_), do: true

  defp js_falsy(val), do: not js_truthy(val)

  defp js_to_number(val) when is_number(val), do: val
  defp js_to_number(true), do: 1
  defp js_to_number(false), do: 0
  defp js_to_number(nil), do: 0
  defp js_to_number(:undefined), do: :nan
  defp js_to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} -> f
      {f, _rest} when trunc(f) == f -> trunc(f)
      {f, _} -> f
      :error -> :nan
    end
  end
  defp js_to_number(_), do: :nan

  defp js_to_int32(val) when is_integer(val), do: val
  defp js_to_int32(val) when is_float(val), do: trunc(val)
  defp js_to_int32(_), do: 0

  defp js_typeof(:undefined), do: "undefined"
  defp js_typeof(nil), do: "object"
  defp js_typeof(true), do: "boolean"
  defp js_typeof(false), do: "boolean"
  defp js_typeof(val) when is_number(val), do: "number"
  defp js_typeof(val) when is_binary(val), do: "string"
  defp js_typeof(%Bytecode.Function{}), do: "function"
  defp js_typeof({:closure, _, %Bytecode.Function{}}), do: "function"
  defp js_typeof(_), do: "object"

  # ── Arithmetic (numeric only — string concat handled separately) ──

  defp js_add(a, b) when is_binary(a) or is_binary(b) do
    js_to_string(a) <> js_to_string(b)
  end
  defp js_add(a, b) when is_number(a) and is_number(b), do: a + b
  defp js_add(a, b), do: js_to_number(a) + js_to_number(b)

  defp js_sub(a, b) when is_number(a) and is_number(b), do: a - b
  defp js_sub(a, b), do: js_to_number(a) - js_to_number(b)

  defp js_mul(a, b) when is_number(a) and is_number(b), do: a * b
  defp js_mul(a, b), do: js_to_number(a) * js_to_number(b)

  defp js_div(a, b) when is_number(a) and is_number(b) do
    if b == 0, do: js_inf_or_nan(a), else: a / b
  end
  defp js_div(a, b), do: js_to_number(a) / js_to_number(b)

  defp js_mod(a, b) when is_number(a) and is_number(b), do: rem(trunc(a), trunc(b))
  defp js_mod(_, _), do: :nan

  defp js_pow(a, b) when is_number(a) and is_number(b), do: :math.pow(a, b)
  defp js_pow(_, _), do: :nan

  defp js_neg(a) when is_number(a), do: -a
  defp js_neg(a), do: -js_to_number(a)

  defp js_inf_or_nan(a) when a > 0, do: :infinity
  defp js_inf_or_nan(a) when a < 0, do: :neg_infinity
  defp js_inf_or_nan(_), do: :nan

  # ── Bitwise ──

  defp js_band(a, b), do: band(js_to_int32(a), js_to_int32(b))
  defp js_bor(a, b), do: bor(js_to_int32(a), js_to_int32(b))
  defp js_bxor(a, b), do: bxor(js_to_int32(a), js_to_int32(b))
  defp js_shl(a, b), do: bsl(js_to_int32(a), band(js_to_int32(b), 31))
  defp js_sar(a, b), do: bsr(js_to_int32(a), band(js_to_int32(b), 31))

  defp js_shr(a, b) do
    ua = js_to_int32(a) &&& 0xFFFFFFFF
    bsr(ua, band(js_to_int32(b), 31))
  end

  # ── Comparison ──

  defp js_lt(a, b) when is_number(a) and is_number(b), do: a < b
  defp js_lt(a, b) when is_binary(a) and is_binary(b), do: a < b
  defp js_lt(a, b), do: js_to_number(a) < js_to_number(b)

  defp js_lte(a, b) when is_number(a) and is_number(b), do: a <= b
  defp js_lte(a, b) when is_binary(a) and is_binary(b), do: a <= b
  defp js_lte(a, b), do: js_to_number(a) <= js_to_number(b)

  defp js_gt(a, b) when is_number(a) and is_number(b), do: a > b
  defp js_gt(a, b) when is_binary(a) and is_binary(b), do: a > b
  defp js_gt(a, b), do: js_to_number(a) > js_to_number(b)

  defp js_gte(a, b) when is_number(a) and is_number(b), do: a >= b
  defp js_gte(a, b) when is_binary(a) and is_binary(b), do: a >= b
  defp js_gte(a, b), do: js_to_number(a) >= js_to_number(b)

  defp js_eq(a, b), do: js_abstract_eq(a, b)
  defp js_neq(a, b), do: not js_abstract_eq(a, b)

  # Abstract equality (==)
  defp js_abstract_eq(nil, nil), do: true
  defp js_abstract_eq(nil, :undefined), do: true
  defp js_abstract_eq(:undefined, nil), do: true
  defp js_abstract_eq(:undefined, :undefined), do: true
  defp js_abstract_eq(a, b) when is_number(a) and is_number(b), do: a == b
  defp js_abstract_eq(a, b) when is_binary(a) and is_binary(b), do: a == b
  defp js_abstract_eq(a, b) when is_boolean(a) and is_boolean(b), do: a == b
  defp js_abstract_eq(true, b), do: js_abstract_eq(1, b)
  defp js_abstract_eq(a, true), do: js_abstract_eq(a, 1)
  defp js_abstract_eq(false, b), do: js_abstract_eq(0, b)
  defp js_abstract_eq(a, false), do: js_abstract_eq(a, 0)
  defp js_abstract_eq(a, b) when is_number(a) and is_binary(b), do: a == js_to_number(b)
  defp js_abstract_eq(a, b) when is_binary(a) and is_number(b), do: js_to_number(a) == b
  defp js_abstract_eq(_, _), do: false

  # ── String conversion ──

  defp js_to_string(:undefined), do: "undefined"
  defp js_to_string(nil), do: "null"
  defp js_to_string(true), do: "true"
  defp js_to_string(false), do: "false"
  defp js_to_string(n) when is_integer(n), do: Integer.to_string(n)
  defp js_to_string(n) when is_float(n), do: Float.to_string(n)
  defp js_to_string(s) when is_binary(s), do: s
  defp js_to_string(_), do: "[object]"

  defp get_arg_value(idx) do
    arg_buf = Process.get(:qb_arg_buf, {})
    if idx < tuple_size(arg_buf), do: elem(arg_buf, idx), else: :undefined
  end

  # ── Global variable resolution ──

  defp resolve_global(atom_idx) do
    name = resolve_atom(atom_idx)
    globals = Process.get(:qb_globals, %{})
    case Map.get(globals, name) do
      nil -> :undefined
      val -> val
    end
  end

  # ── Atom resolution ──

  @js_atom_end 229

  defp resolve_atom(:empty_string), do: ""
  defp resolve_atom({:predefined, idx}) when idx < @js_atom_end do
    case PredefinedAtoms.lookup(idx) do
      nil -> {:predefined_atom, idx}
      name -> name
    end
  end
  defp resolve_atom({:tagged_int, val}), do: val
  defp resolve_atom(idx) when is_integer(idx) and idx >= 0 do
    atoms = Process.get(:qb_atoms, {})
    if idx < tuple_size(atoms), do: elem(atoms, idx), else: {:atom, idx}
  end
  defp resolve_atom(other), do: other
end
