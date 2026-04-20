defmodule QuickBEAM.BeamVM.Compiler.Lowering.Ops do
  @moduledoc false

  alias QuickBEAM.BeamVM.Compiler.{Analysis, RuntimeHelpers}
  alias QuickBEAM.BeamVM.Compiler.Lowering.State
  alias QuickBEAM.BeamVM.Interpreter.Values

  @tdz :__tdz__

  def lower_instruction({op, args}, idx, next_entry, _arg_count, state, stack_depths) do
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
        {:error, {:unsupported_literal, :empty_string}}

      {{:ok, :object}, []} ->
        {:ok, State.push(state, State.compiler_call(:new_object, []))}

      {{:ok, :array_from}, [argc]} ->
        State.array_from_call(state, argc)

      {{:ok, :push_const}, [const_idx]} ->
        push_const(state, const_idx)

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

  defp push_const(_state, idx), do: {:error, {:unsupported_const, idx}}
end
