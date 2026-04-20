defmodule QuickBEAM.BeamVM.Compiler.Lowering.Ops do
  @moduledoc false

  alias QuickBEAM.BeamVM.Compiler.{Analysis, RuntimeHelpers}
  alias QuickBEAM.BeamVM.Compiler.Lowering.State
  alias QuickBEAM.BeamVM.Interpreter.Values

  @tdz :__tdz__

  def lower_instruction({op, args}, idx, next_entry, arg_count, state, stack_depths, constants) do
    name = Analysis.opcode_name(op)

    case {name, args} do
      {{:ok, :push_i32}, [value]} ->
        {:ok, State.push(state, State.integer(value))}

      {{:ok, :push_i16}, [value]} ->
        {:ok, State.push(state, State.integer(value))}

      {{:ok, :push_i8}, [value]} ->
        {:ok, State.push(state, State.integer(value))}

      {{:ok, :push_minus1}, [_]} ->
        {:ok, State.push(state, State.integer(-1))}

      {{:ok, :push_0}, [_]} ->
        {:ok, State.push(state, State.integer(0))}

      {{:ok, :push_1}, [_]} ->
        {:ok, State.push(state, State.integer(1))}

      {{:ok, :push_2}, [_]} ->
        {:ok, State.push(state, State.integer(2))}

      {{:ok, :push_3}, [_]} ->
        {:ok, State.push(state, State.integer(3))}

      {{:ok, :push_4}, [_]} ->
        {:ok, State.push(state, State.integer(4))}

      {{:ok, :push_5}, [_]} ->
        {:ok, State.push(state, State.integer(5))}

      {{:ok, :push_6}, [_]} ->
        {:ok, State.push(state, State.integer(6))}

      {{:ok, :push_7}, [_]} ->
        {:ok, State.push(state, State.integer(7))}

      {{:ok, :push_true}, []} ->
        {:ok, State.push(state, State.atom(true))}

      {{:ok, :push_false}, []} ->
        {:ok, State.push(state, State.atom(false))}

      {{:ok, :null}, []} ->
        {:ok, State.push(state, State.atom(nil))}

      {{:ok, :undefined}, []} ->
        {:ok, State.push(state, State.atom(:undefined))}

      {{:ok, :push_empty_string}, []} ->
        {:ok, State.push(state, State.literal(""))}

      {{:ok, :object}, []} ->
        {:ok, State.push(state, State.compiler_call(:new_object, []))}

      {{:ok, :array_from}, [argc]} ->
        State.array_from_call(state, argc)

      {{:ok, :push_const}, [const_idx]} ->
        push_const(state, constants, const_idx)

      {{:ok, :fclosure}, [const_idx]} ->
        lower_fclosure(state, constants, arg_count, const_idx)

      {{:ok, :fclosure8}, [const_idx]} ->
        lower_fclosure(state, constants, arg_count, const_idx)

      {{:ok, :push_atom_value}, [atom_idx]} ->
        {:ok, State.push(state, State.compiler_call(:push_atom_value, [State.literal(atom_idx)]))}

      {{:ok, :get_var}, [atom_idx]} ->
        {:ok, State.push(state, State.compiler_call(:get_var, [State.literal(atom_idx)]))}

      {{:ok, :get_var_undef}, [atom_idx]} ->
        {:ok, State.push(state, State.compiler_call(:get_var_undef, [State.literal(atom_idx)]))}

      {{:ok, :get_arg}, [slot_idx]} ->
        {:ok, State.push(state, State.slot_expr(state, slot_idx))}

      {{:ok, :get_arg0}, [slot_idx]} ->
        {:ok, State.push(state, State.slot_expr(state, slot_idx))}

      {{:ok, :get_arg1}, [slot_idx]} ->
        {:ok, State.push(state, State.slot_expr(state, slot_idx))}

      {{:ok, :get_arg2}, [slot_idx]} ->
        {:ok, State.push(state, State.slot_expr(state, slot_idx))}

      {{:ok, :get_arg3}, [slot_idx]} ->
        {:ok, State.push(state, State.slot_expr(state, slot_idx))}

      {{:ok, :get_loc}, [slot_idx]} ->
        {:ok, State.push(state, State.slot_expr(state, slot_idx))}

      {{:ok, :get_loc0}, [slot_idx]} ->
        {:ok, State.push(state, State.slot_expr(state, slot_idx))}

      {{:ok, :get_loc1}, [slot_idx]} ->
        {:ok, State.push(state, State.slot_expr(state, slot_idx))}

      {{:ok, :get_loc2}, [slot_idx]} ->
        {:ok, State.push(state, State.slot_expr(state, slot_idx))}

      {{:ok, :get_loc3}, [slot_idx]} ->
        {:ok, State.push(state, State.slot_expr(state, slot_idx))}

      {{:ok, :get_loc8}, [slot_idx]} ->
        {:ok, State.push(state, State.slot_expr(state, slot_idx))}

      {{:ok, :get_loc0_loc1}, [slot0, slot1]} ->
        {:ok,
         %{
           state
           | stack: [State.slot_expr(state, slot1), State.slot_expr(state, slot0) | state.stack]
         }}

      {{:ok, :get_loc_check}, [slot_idx]} ->
        {:ok,
         State.push(
           state,
           State.compiler_call(:ensure_initialized_local!, [State.slot_expr(state, slot_idx)])
         )}

      {{:ok, :set_loc_uninitialized}, [slot_idx]} ->
        {:ok, State.put_slot(state, slot_idx, State.atom(@tdz))}

      {{:ok, :put_loc}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc0}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc1}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc2}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc3}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc8}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg0}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg1}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg2}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg3}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc_check}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false, :ensure_initialized_local!)

      {{:ok, :put_loc_check_init}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :set_loc}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc0}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc1}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc2}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc3}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg0}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg1}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg2}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg3}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :dup}, []} ->
        State.duplicate_top(state)

      {{:ok, :dup2}, []} ->
        State.duplicate_top_two(state)

      {{:ok, :drop}, []} ->
        State.drop_top(state)

      {{:ok, :swap}, []} ->
        State.swap_top(state)

      {{:ok, :neg}, []} ->
        State.unary_local_call(state, :op_neg)

      {{:ok, :plus}, []} ->
        State.unary_local_call(state, :op_plus)

      {{:ok, :not}, []} ->
        State.unary_call(state, RuntimeHelpers, :bit_not)

      {{:ok, :lnot}, []} ->
        State.unary_call(state, RuntimeHelpers, :lnot)

      {{:ok, :is_undefined}, []} ->
        State.unary_call(state, RuntimeHelpers, :is_undefined)

      {{:ok, :is_null}, []} ->
        State.unary_call(state, RuntimeHelpers, :is_null)

      {{:ok, :typeof_is_undefined}, []} ->
        State.unary_call(state, RuntimeHelpers, :typeof_is_undefined)

      {{:ok, :typeof_is_function}, []} ->
        State.unary_call(state, RuntimeHelpers, :typeof_is_function)

      {{:ok, :inc}, []} ->
        State.unary_call(state, RuntimeHelpers, :inc)

      {{:ok, :dec}, []} ->
        State.unary_call(state, RuntimeHelpers, :dec)

      {{:ok, :inc_loc}, [slot_idx]} ->
        State.inc_slot(state, slot_idx)

      {{:ok, :dec_loc}, [slot_idx]} ->
        State.dec_slot(state, slot_idx)

      {{:ok, :add_loc}, [slot_idx]} ->
        State.add_to_slot(state, slot_idx)

      {{:ok, :post_inc}, []} ->
        State.post_update(state, :post_inc)

      {{:ok, :post_dec}, []} ->
        State.post_update(state, :post_dec)

      {{:ok, :add}, []} ->
        State.binary_local_call(state, :op_add)

      {{:ok, :sub}, []} ->
        State.binary_local_call(state, :op_sub)

      {{:ok, :mul}, []} ->
        State.binary_local_call(state, :op_mul)

      {{:ok, :div}, []} ->
        State.binary_local_call(state, :op_div)

      {{:ok, :mod}, []} ->
        State.binary_call(state, Values, :mod)

      {{:ok, :pow}, []} ->
        State.binary_call(state, Values, :pow)

      {{:ok, :band}, []} ->
        State.binary_call(state, Values, :band)

      {{:ok, :bor}, []} ->
        State.binary_call(state, Values, :bor)

      {{:ok, :bxor}, []} ->
        State.binary_call(state, Values, :bxor)

      {{:ok, :shl}, []} ->
        State.binary_call(state, Values, :shl)

      {{:ok, :sar}, []} ->
        State.binary_call(state, Values, :sar)

      {{:ok, :shr}, []} ->
        State.binary_call(state, Values, :shr)

      {{:ok, :typeof}, []} ->
        State.unary_call(state, Values, :typeof)

      {{:ok, :instanceof}, []} ->
        State.binary_call(state, RuntimeHelpers, :instanceof)

      {{:ok, :in}, []} ->
        State.in_call(state)

      {{:ok, :delete}, []} ->
        State.delete_call(state)

      {{:ok, :get_length}, []} ->
        State.unary_call(state, RuntimeHelpers, :get_length)

      {{:ok, :get_array_el}, []} ->
        State.binary_call(state, QuickBEAM.BeamVM.Interpreter.Objects, :get_element)

      {{:ok, :get_field}, [atom_idx]} ->
        State.unary_call(state, RuntimeHelpers, :get_field, [State.literal(atom_idx)])

      {{:ok, :get_field2}, [atom_idx]} ->
        State.get_field2(state, atom_idx)

      {{:ok, :put_field}, [atom_idx]} ->
        State.put_field_call(state, atom_idx)

      {{:ok, :define_field}, [atom_idx]} ->
        State.define_field_call(state, atom_idx)

      {{:ok, :put_array_el}, []} ->
        State.put_array_el_call(state)

      {{:ok, :append}, []} ->
        State.append_call(state)

      {{:ok, :copy_data_properties}, [mask]} ->
        State.copy_data_properties_call(state, mask)

      {{:ok, :to_propkey}, []} ->
        {:ok, state}

      {{:ok, :to_propkey2}, []} ->
        {:ok, state}

      {{:ok, :lt}, []} ->
        State.binary_local_call(state, :op_lt)

      {{:ok, :lte}, []} ->
        State.binary_local_call(state, :op_lte)

      {{:ok, :gt}, []} ->
        State.binary_local_call(state, :op_gt)

      {{:ok, :gte}, []} ->
        State.binary_local_call(state, :op_gte)

      {{:ok, :eq}, []} ->
        State.binary_local_call(state, :op_eq)

      {{:ok, :neq}, []} ->
        State.binary_local_call(state, :op_neq)

      {{:ok, :strict_eq}, []} ->
        State.binary_local_call(state, :op_strict_eq)

      {{:ok, :strict_neq}, []} ->
        State.binary_local_call(state, :op_strict_neq)

      {{:ok, :for_in_start}, []} ->
        lower_for_in_start(state)

      {{:ok, :for_in_next}, []} ->
        lower_for_in_next(state)

      {{:ok, :for_of_start}, []} ->
        lower_for_of_start(state)

      {{:ok, :for_of_next}, [iter_idx]} ->
        lower_for_of_next(state, iter_idx)

      {{:ok, :iterator_close}, []} ->
        lower_iterator_close(state)

      {{:ok, :nip_catch}, []} ->
        State.nip_catch(state)

      {{:ok, :throw}, []} ->
        State.throw_top(state)

      {{:ok, :call_constructor}, [argc]} ->
        State.invoke_constructor_call(state, argc)

      {{:ok, :call}, [argc]} ->
        State.invoke_call(state, argc)

      {{:ok, :call0}, [argc]} ->
        State.invoke_call(state, argc)

      {{:ok, :call1}, [argc]} ->
        State.invoke_call(state, argc)

      {{:ok, :call2}, [argc]} ->
        State.invoke_call(state, argc)

      {{:ok, :call3}, [argc]} ->
        State.invoke_call(state, argc)

      {{:ok, :tail_call}, [argc]} ->
        State.invoke_tail_call(state, argc)

      {{:ok, :call_method}, [argc]} ->
        State.invoke_method_call(state, argc)

      {{:ok, :tail_call_method}, [argc]} ->
        State.invoke_tail_method_call(state, argc)

      {{:ok, :is_undefined_or_null}, []} ->
        State.unary_call(state, RuntimeHelpers, :is_undefined_or_null)

      {{:ok, :if_false}, [target]} ->
        State.branch(state, idx, next_entry, target, false, stack_depths)

      {{:ok, :if_false8}, [target]} ->
        State.branch(state, idx, next_entry, target, false, stack_depths)

      {{:ok, :if_true}, [target]} ->
        State.branch(state, idx, next_entry, target, true, stack_depths)

      {{:ok, :if_true8}, [target]} ->
        State.branch(state, idx, next_entry, target, true, stack_depths)

      {{:ok, :goto}, [target]} ->
        State.goto(state, target, stack_depths)

      {{:ok, :goto8}, [target]} ->
        State.goto(state, target, stack_depths)

      {{:ok, :goto16}, [target]} ->
        State.goto(state, target, stack_depths)

      {{:ok, :return}, []} ->
        State.return_top(state)

      {{:ok, :return_undef}, []} ->
        {:done, state.body ++ [State.atom(:undefined)]}

      {{:ok, :nop}, []} ->
        {:ok, state}

      {{:error, _} = error, _} ->
        error

      {{:ok, name}, _} ->
        {:error, {:unsupported_opcode, name}}
    end
  end

  defp lower_for_in_start(state) do
    with {:ok, obj, state} <- State.pop(state) do
      {:ok, State.push(state, State.compiler_call(:for_in_start, [obj]))}
    end
  end

  defp lower_for_in_next(state) do
    with {:ok, state, iter} <- State.bind_stack_entry(state, 0) do
      {result, state} =
        State.bind(
          state,
          State.temp_name(state.temp),
          State.compiler_call(:for_in_next, [iter])
        )

      state = %{state | stack: List.replace_at(state.stack, 0, State.tuple_element(result, 3))}
      state = State.push(state, State.tuple_element(result, 2))
      state = State.push(state, State.tuple_element(result, 1))
      {:ok, state}
    else
      :error -> {:error, :for_in_state_missing}
      {:error, _} = error -> error
    end
  end

  defp lower_for_of_start(state) do
    with {:ok, obj, state} <- State.pop(state) do
      {pair, state} =
        State.bind(state, State.temp_name(state.temp), State.compiler_call(:for_of_start, [obj]))

      state = State.push(state, State.tuple_element(pair, 1))
      state = State.push(state, State.tuple_element(pair, 2))
      state = State.push(state, State.integer(0))
      {:ok, state}
    end
  end

  defp lower_for_of_next(state, iter_idx) do
    with {:ok, state, next_fn} <- State.bind_stack_entry(state, iter_idx + 1),
         {:ok, state, iter_obj} <- State.bind_stack_entry(state, iter_idx + 2) do
      {result, state} =
        State.bind(
          state,
          State.temp_name(state.temp),
          State.compiler_call(:for_of_next, [next_fn, iter_obj])
        )

      state = %{
        state
        | stack: List.replace_at(state.stack, iter_idx + 2, State.tuple_element(result, 3))
      }

      state = State.push(state, State.tuple_element(result, 2))
      state = State.push(state, State.tuple_element(result, 1))
      {:ok, state}
    else
      :error -> {:error, {:for_of_state_missing, iter_idx}}
      {:error, _} = error -> error
    end
  end

  defp lower_iterator_close(state) do
    with {:ok, _catch_offset, state} <- State.pop(state),
         {:ok, _next_fn, state} <- State.pop(state),
         {:ok, iter_obj, state} <- State.pop(state) do
      {:ok, %{state | body: state.body ++ [State.compiler_call(:iterator_close, [iter_obj])]}}
    end
  end

  defp lower_fclosure(state, constants, arg_count, const_idx) do
    case Enum.at(constants, const_idx) do
      %QuickBEAM.BeamVM.Bytecode.Function{closure_vars: []} = fun ->
        {:ok, State.push(state, State.literal(fun))}

      %QuickBEAM.BeamVM.Bytecode.Function{} = fun ->
        with {:ok, state, entries} <-
               lower_closure_entries(state, arg_count, fun.closure_vars, []) do
          closure =
            State.tuple_expr([
              State.atom(:closure),
              State.map_expr(Enum.reverse(entries)),
              State.literal(fun)
            ])

          {:ok, State.push(state, closure)}
        end

      nil ->
        {:error, {:unsupported_const, const_idx}}

      other ->
        {:error, {:unsupported_fclosure_const, const_idx, other}}
    end
  end

  defp lower_closure_entries(state, _arg_count, [], acc), do: {:ok, state, acc}

  defp lower_closure_entries(state, arg_count, [cv | rest], acc) do
    with {:ok, slot_idx} <- closure_slot_index(arg_count, cv),
         {:ok, state, cell} <- State.ensure_capture_cell(state, slot_idx) do
      key = State.literal({cv.closure_type, cv.var_idx})
      lower_closure_entries(state, arg_count, rest, [{key, cell} | acc])
    end
  end

  defp closure_slot_index(_arg_count, %{closure_type: 1, var_idx: idx}), do: {:ok, idx}
  defp closure_slot_index(arg_count, %{closure_type: 0, var_idx: idx}), do: {:ok, idx + arg_count}

  defp closure_slot_index(_arg_count, %{closure_type: 2, var_idx: idx}),
    do: {:error, {:closure_var_ref_not_supported, idx}}

  defp closure_slot_index(_arg_count, %{closure_type: type, var_idx: idx}),
    do: {:error, {:closure_type_not_supported, type, idx}}

  defp push_const(state, constants, idx) do
    case Enum.at(constants, idx) do
      nil ->
        {:error, {:unsupported_const, idx}}

      value
      when is_integer(value) or is_float(value) or is_binary(value) or is_boolean(value) or
             is_nil(value) ->
        {:ok, State.push(state, State.literal(value))}

      :undefined ->
        {:ok, State.push(state, State.atom(:undefined))}

      %QuickBEAM.BeamVM.Bytecode.Function{} = fun when fun.closure_vars == [] ->
        {:ok, State.push(state, State.literal(fun))}

      _ ->
        {:error, {:unsupported_const, idx}}
    end
  end
end
