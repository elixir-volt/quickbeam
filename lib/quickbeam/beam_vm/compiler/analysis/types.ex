defmodule QuickBEAM.BeamVM.Compiler.Analysis.Types do
  @moduledoc false

  alias QuickBEAM.BeamVM.Bytecode
  alias QuickBEAM.BeamVM.Compiler.Analysis.{CFG, Stack}
  alias QuickBEAM.BeamVM.Decoder

  def infer_block_entry_types(fun, instructions, entries, stack_depths) do
    slot_count = fun.arg_count + fun.var_count
    initial = initial_type_state(slot_count, Map.get(stack_depths, 0, 0))

    iterate_block_entry_types(
      instructions,
      entries,
      stack_depths,
      fun.constants,
      %{0 => initial},
      :unknown,
      0
    )
  end

  def function_type(%Bytecode.Function{} = fun) do
    stack = Process.get(:qb_function_type_stack, MapSet.new())

    if MapSet.member?(stack, fun.byte_code) do
      :function
    else
      next_stack = MapSet.put(stack, fun.byte_code)
      Process.put(:qb_function_type_stack, next_stack)

      try do
        case Decoder.decode(fun.byte_code, fun.arg_count) do
          {:ok, instructions} ->
            entries = CFG.block_entries(instructions)

            with {:ok, stack_depths} <- Stack.infer_block_stack_depths(instructions, entries),
                 {:ok, {_entry_types, return_type}} <-
                   infer_block_entry_types(fun, instructions, entries, stack_depths) do
              {:function, return_type}
            else
              _ -> :function
            end

          _ ->
            :function
        end
      after
        if MapSet.size(stack) == 0,
          do: Process.delete(:qb_function_type_stack),
          else: Process.put(:qb_function_type_stack, stack)
      end
    end
  end

  defp iterate_block_entry_types(
         instructions,
         entries,
         stack_depths,
         constants,
         entry_types,
         return_type,
         iteration
       )
       when iteration < 12 do
    with {:ok, {next_entry_types, next_return_type}} <-
           walk_block_entry_types(
             instructions,
             entries,
             stack_depths,
             constants,
             entry_types,
             return_type
           ) do
      if next_entry_types == entry_types and next_return_type == return_type do
        {:ok, {next_entry_types, next_return_type}}
      else
        iterate_block_entry_types(
          instructions,
          entries,
          stack_depths,
          constants,
          next_entry_types,
          next_return_type,
          iteration + 1
        )
      end
    end
  end

  defp iterate_block_entry_types(
         _instructions,
         _entries,
         _stack_depths,
         _constants,
         _entry_types,
         _return_type,
         iteration
       ) do
    {:error, {:type_inference_did_not_converge, iteration}}
  end

  defp walk_block_entry_types(
         instructions,
         entries,
         stack_depths,
         constants,
         entry_types,
         return_type
       ) do
    Enum.reduce_while(entries, {:ok, {entry_types, return_type}}, fn start, {:ok, acc} ->
      case Map.fetch(elem(acc, 0), start) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, state} ->
          next = CFG.next_entry(entries, start)

          case simulate_block_types(
                 instructions,
                 entries,
                 stack_depths,
                 constants,
                 start,
                 next,
                 state,
                 elem(acc, 1)
               ) do
            {:ok, {updates, block_return_type}} ->
              merged_entry_types = merge_block_updates(elem(acc, 0), updates)
              merged_return_type = join_type(elem(acc, 1), block_return_type)
              {:cont, {:ok, {merged_entry_types, merged_return_type}}}

            {:error, _} = error ->
              {:halt, error}
          end
      end
    end)
  end

  defp simulate_block_types(
         instructions,
         entries,
         stack_depths,
         _constants,
         idx,
         next_entry,
         state,
         return_type
       )
       when idx >= length(instructions) do
    {:error,
     {:missing_type_terminator, idx, next_entry, state, return_type, entries, stack_depths}}
  end

  defp simulate_block_types(
         _instructions,
         _entries,
         _stack_depths,
         _constants,
         idx,
         idx,
         state,
         return_type
       ) do
    {:ok, {[{idx, state}], return_type}}
  end

  defp simulate_block_types(
         instructions,
         entries,
         stack_depths,
         constants,
         idx,
         next_entry,
         state,
         return_type
       ) do
    instruction = Enum.at(instructions, idx)

    with {:ok, result} <- transfer_types(instruction, state, return_type, constants) do
      case result do
        {:continue, next_state, next_return_type} ->
          simulate_block_types(
            instructions,
            entries,
            stack_depths,
            constants,
            idx + 1,
            next_entry,
            next_state,
            next_return_type
          )

        {:catch, target, next_state, next_return_type} ->
          with {:ok, {updates, final_return_type}} <-
                 simulate_block_types(
                   instructions,
                   entries,
                   stack_depths,
                   constants,
                   idx + 1,
                   next_entry,
                   next_state,
                   next_return_type
                 ) do
            {:ok, {[{target, next_state} | updates], final_return_type}}
          end

        {:branch, target, next_state, next_return_type} ->
          if is_nil(next_entry) do
            {:error, {:missing_fallthrough_type_block, target, idx}}
          else
            {:ok, {[{target, next_state}, {next_entry, next_state}], next_return_type}}
          end

        {:goto, target, next_state, next_return_type} ->
          {:ok, {[{target, next_state}], next_return_type}}

        {:halt, next_return_type} ->
          {:ok, {[], next_return_type}}
      end
    end
  end

  defp transfer_types({op, args}, state, return_type, constants) do
    case {CFG.opcode_name(op), args} do
      {{:ok, name}, [value]} when name in [:push_i32, :push_i16, :push_i8] ->
        {:ok, {:continue, push_type(state, literal_type(value)), return_type}}

      {{:ok, :push_minus1}, _} ->
        {:ok, {:continue, push_type(state, :integer), return_type}}

      {{:ok, name}, _}
      when name in [:push_0, :push_1, :push_2, :push_3, :push_4, :push_5, :push_6, :push_7] ->
        {:ok, {:continue, push_type(state, :integer), return_type}}

      {{:ok, name}, _} when name in [:push_true, :push_false] ->
        {:ok, {:continue, push_type(state, :boolean), return_type}}

      {{:ok, :null}, _} ->
        {:ok, {:continue, push_type(state, :null), return_type}}

      {{:ok, :undefined}, _} ->
        {:ok, {:continue, push_type(state, :undefined), return_type}}

      {{:ok, :push_empty_string}, _} ->
        {:ok, {:continue, push_type(state, :string), return_type}}

      {{:ok, :object}, _} ->
        {:ok, {:continue, push_type(state, :object), return_type}}

      {{:ok, :array_from}, [argc]} ->
        with {:ok, state} <- pop_types(state, argc) do
          {:ok, {:continue, push_type(state, :object), return_type}}
        end

      {{:ok, name}, [const_idx]} when name in [:push_const, :push_const8] ->
        {:ok, {:continue, push_type(state, constant_type(constants, const_idx)), return_type}}

      {{:ok, name}, [const_idx]} when name in [:fclosure, :fclosure8] ->
        {:ok, {:continue, push_type(state, closure_type(constants, const_idx)), return_type}}

      {{:ok, :special_object}, [type]} ->
        {:ok, {:continue, push_type(state, special_object_type(type)), return_type}}

      {{:ok, name}, [slot_idx]}
      when name in [
             :get_arg,
             :get_arg0,
             :get_arg1,
             :get_arg2,
             :get_arg3,
             :get_loc,
             :get_loc0,
             :get_loc1,
             :get_loc2,
             :get_loc3,
             :get_loc8,
             :get_loc_check
           ] ->
        {:ok, {:continue, push_type(state, slot_type(state, slot_idx)), return_type}}

      {{:ok, :get_loc0_loc1}, [slot0, slot1]} ->
        {:ok,
         {:continue,
          state
          |> push_type(slot_type(state, slot0))
          |> push_type(slot_type(state, slot1)), return_type}}

      {{:ok, name}, [_idx]}
      when name in [
             :get_var_ref,
             :get_var_ref0,
             :get_var_ref1,
             :get_var_ref2,
             :get_var_ref3,
             :get_var_ref_check
           ] ->
        {:ok, {:continue, push_type(state, :unknown), return_type}}

      {{:ok, :set_loc_uninitialized}, [slot_idx]} ->
        {:ok, {:continue, put_slot_type(state, slot_idx, :unknown), return_type}}

      {{:ok, name}, [slot_idx]}
      when name in [
             :put_loc,
             :put_loc0,
             :put_loc1,
             :put_loc2,
             :put_loc3,
             :put_loc8,
             :put_arg,
             :put_arg0,
             :put_arg1,
             :put_arg2,
             :put_arg3,
             :put_loc_check,
             :put_loc_check_init
           ] ->
        with {:ok, type, state} <- pop_type(state) do
          {:ok, {:continue, put_slot_type(state, slot_idx, type), return_type}}
        end

      {{:ok, name}, [_idx]}
      when name in [
             :put_var_ref,
             :put_var_ref0,
             :put_var_ref1,
             :put_var_ref2,
             :put_var_ref3,
             :put_var_ref_check,
             :put_var_ref_check_init
           ] ->
        with {:ok, _type, state} <- pop_type(state) do
          {:ok, {:continue, state, return_type}}
        end

      {{:ok, name}, [slot_idx]}
      when name in [
             :set_loc,
             :set_loc0,
             :set_loc1,
             :set_loc2,
             :set_loc3,
             :set_loc8,
             :set_arg,
             :set_arg0,
             :set_arg1,
             :set_arg2,
             :set_arg3
           ] ->
        with {:ok, type, state} <- pop_type(state) do
          next_state = state |> put_slot_type(slot_idx, type) |> push_type(type)
          {:ok, {:continue, next_state, return_type}}
        end

      {{:ok, name}, [_idx]}
      when name in [:set_var_ref, :set_var_ref0, :set_var_ref1, :set_var_ref2, :set_var_ref3] ->
        with {:ok, _type, state} <- pop_type(state) do
          {:ok, {:continue, push_type(state, :unknown), return_type}}
        end

      {{:ok, :dup}, _} ->
        with {:ok, type, state} <- pop_type(state) do
          next_state = state |> push_type(type) |> push_type(type)
          {:ok, {:continue, next_state, return_type}}
        end

      {{:ok, :dup2}, _} ->
        with {:ok, first, state} <- pop_type(state),
             {:ok, second, state} <- pop_type(state) do
          next_state =
            state
            |> push_type(second)
            |> push_type(first)
            |> push_type(second)
            |> push_type(first)

          {:ok, {:continue, next_state, return_type}}
        end

      {{:ok, :drop}, _} ->
        with {:ok, _type, state} <- pop_type(state) do
          {:ok, {:continue, state, return_type}}
        end

      {{:ok, :swap}, _} ->
        with {:ok, first, state} <- pop_type(state),
             {:ok, second, state} <- pop_type(state) do
          {:ok, {:continue, state |> push_type(first) |> push_type(second), return_type}}
        end

      {{:ok, :nip_catch}, _} ->
        with {:ok, value_type, state} <- pop_type(state),
             {:ok, _catch_type, state} <- pop_type(state) do
          {:ok, {:continue, push_type(state, value_type), return_type}}
        end

      {{:ok, name}, _}
      when name in [
             :neg,
             :plus,
             :typeof,
             :delete,
             :not,
             :lnot,
             :is_undefined,
             :is_null,
             :typeof_is_undefined,
             :typeof_is_function,
             :is_undefined_or_null
           ] ->
        transfer_unary_type(name, state, return_type)

      {{:ok, name}, _}
      when name in [
             :add,
             :sub,
             :mul,
             :div,
             :mod,
             :pow,
             :lt,
             :lte,
             :gt,
             :gte,
             :eq,
             :neq,
             :strict_eq,
             :strict_neq,
             :shl,
             :sar,
             :shr,
             :band,
             :bor,
             :bxor,
             :instanceof,
             :in
           ] ->
        transfer_binaryish_type(name, state, return_type)

      {{:ok, name}, _} when name in [:inc, :dec] ->
        with {:ok, type, state} <- pop_type(state) do
          next_type = if type == :integer, do: :integer, else: :number
          {:ok, {:continue, push_type(state, next_type), return_type}}
        end

      {{:ok, name}, _} when name in [:post_inc, :post_dec] ->
        with {:ok, type, state} <- pop_type(state) do
          next_type = if type == :integer, do: :integer, else: :number
          next_state = state |> push_type(next_type) |> push_type(next_type)
          {:ok, {:continue, next_state, return_type}}
        end

      {{:ok, :get_length}, _} ->
        with {:ok, _type, state} <- pop_type(state) do
          {:ok, {:continue, push_type(state, :integer), return_type}}
        end

      {{:ok, :get_field}, _} ->
        with {:ok, _obj_type, state} <- pop_type(state) do
          {:ok, {:continue, push_type(state, :unknown), return_type}}
        end

      {{:ok, :get_field2}, _} ->
        with {:ok, obj_type, state} <- pop_type(state) do
          next_state = state |> push_type(obj_type) |> push_type(:unknown)
          {:ok, {:continue, next_state, return_type}}
        end

      {{:ok, name}, _} when name in [:get_array_el, :get_super_value, :get_private_field] ->
        with {:ok, _idx_type, state} <- pop_type(state),
             {:ok, _obj_type, state} <- pop_type(state) do
          {:ok, {:continue, push_type(state, :unknown), return_type}}
        end

      {{:ok, :get_array_el2}, _} ->
        with {:ok, _idx_type, state} <- pop_type(state),
             {:ok, obj_type, state} <- pop_type(state) do
          next_state = state |> push_type(obj_type) |> push_type(:unknown)
          {:ok, {:continue, next_state, return_type}}
        end

      {{:ok, name}, [argc]} when name in [:call, :call0, :call1, :call2, :call3] ->
        with {:ok, state} <- pop_types(state, argc),
             {:ok, fun_type, state} <- pop_type(state) do
          {:ok,
           {:continue, push_type(state, invoke_result_type(fun_type, return_type)), return_type}}
        end

      {{:ok, :tail_call}, [argc]} ->
        with {:ok, state} <- pop_types(state, argc),
             {:ok, fun_type, _state} <- pop_type(state) do
          {:ok, {:halt, join_type(return_type, invoke_result_type(fun_type, return_type))}}
        end

      {{:ok, :call_method}, [argc]} ->
        with {:ok, state} <- pop_types(state, argc),
             {:ok, fun_type, state} <- pop_type(state),
             {:ok, _obj_type, state} <- pop_type(state) do
          {:ok,
           {:continue, push_type(state, invoke_result_type(fun_type, return_type)), return_type}}
        end

      {{:ok, :tail_call_method}, [argc]} ->
        with {:ok, state} <- pop_types(state, argc),
             {:ok, fun_type, state} <- pop_type(state),
             {:ok, _obj_type, _state} <- pop_type(state) do
          {:ok, {:halt, join_type(return_type, invoke_result_type(fun_type, return_type))}}
        end

      {{:ok, :call_constructor}, [argc]} ->
        with {:ok, state} <- pop_types(state, argc),
             {:ok, _new_target_type, state} <- pop_type(state),
             {:ok, _ctor_type, state} <- pop_type(state) do
          {:ok, {:continue, push_type(state, :object), return_type}}
        end

      {{:ok, :append}, _} ->
        with {:ok, _obj_type, state} <- pop_type(state),
             {:ok, _idx_type, state} <- pop_type(state),
             {:ok, _arr_type, state} <- pop_type(state) do
          next_state = state |> push_type(:object) |> push_type(:number)
          {:ok, {:continue, next_state, return_type}}
        end

      {{:ok, :copy_data_properties}, _} ->
        {:ok, {:continue, state, return_type}}

      {{:ok, :define_field}, _} ->
        with {:ok, _val_type, state} <- pop_type(state),
             {:ok, _obj_type, state} <- pop_type(state) do
          {:ok, {:continue, push_type(state, :object), return_type}}
        end

      {{:ok, name}, _}
      when name in [
             :put_field,
             :put_array_el,
             :put_super_value,
             :put_private_field,
             :define_private_field,
             :check_brand,
             :add_brand,
             :set_home_object
           ] ->
        with {:ok, state} <- apply_generic_stack_effect(state, op, args) do
          {:ok, {:continue, state, return_type}}
        end

      {{:ok, name}, _} when name in [:define_method, :define_method_computed] ->
        with {:ok, state} <- apply_generic_stack_effect(state, op, args) do
          {:ok, {:continue, push_type(state, :object), return_type}}
        end

      {{:ok, :define_class}, _} ->
        with {:ok, _ctor_type, state} <- pop_type(state),
             {:ok, _parent_type, state} <- pop_type(state) do
          next_state = state |> push_type(:function) |> push_type(:object)
          {:ok, {:continue, next_state, return_type}}
        end

      {{:ok, :set_name}, _} ->
        with {:ok, _fun_type, state} <- pop_type(state) do
          {:ok, {:continue, push_type(state, :function), return_type}}
        end

      {{:ok, :set_name_computed}, _} ->
        with {:ok, fun_type, state} <- pop_type(state),
             {:ok, name_type, state} <- pop_type(state) do
          next_state = state |> push_type(name_type) |> push_type(join_type(fun_type, :function))
          {:ok, {:continue, next_state, return_type}}
        end

      {{:ok, :push_this}, _} ->
        {:ok, {:continue, push_type(state, :object), return_type}}

      {{:ok, :push_atom_value}, _} ->
        {:ok, {:continue, push_type(state, :string), return_type}}

      {{:ok, :close_loc}, _} ->
        {:ok, {:continue, state, return_type}}

      {{:ok, :for_in_start}, _} ->
        with {:ok, _src_type, state} <- pop_type(state) do
          {:ok, {:continue, push_type(state, :unknown), return_type}}
        end

      {{:ok, :for_in_next}, _} ->
        case state.stack_types do
          [iter_type | rest] ->
            next_state = %{state | stack_types: [iter_type | rest]}
            next_state = next_state |> push_type(:unknown) |> push_type(:boolean)
            {:ok, {:continue, next_state, return_type}}

          _ ->
            {:error, :stack_underflow}
        end

      {{:ok, :for_of_start}, _} ->
        with {:ok, _src_type, state} <- pop_type(state) do
          next_state = state |> push_type(:object) |> push_type(:function) |> push_type(:integer)
          {:ok, {:continue, next_state, return_type}}
        end

      {{:ok, :for_of_next}, _} ->
        case state.stack_types do
          [catch_type, next_type, _iter_type | rest] ->
            next_state = %{state | stack_types: [catch_type, next_type, :object | rest]}
            next_state = next_state |> push_type(:unknown) |> push_type(:boolean)
            {:ok, {:continue, next_state, return_type}}

          _ ->
            {:error, :stack_underflow}
        end

      {{:ok, :iterator_close}, _} ->
        with {:ok, _catch_type, state} <- pop_type(state),
             {:ok, _next_type, state} <- pop_type(state),
             {:ok, _iter_type, state} <- pop_type(state) do
          {:ok, {:continue, state, return_type}}
        end

      {{:ok, :catch}, [target]} ->
        with {:ok, state} <- apply_generic_stack_effect(state, op, args) do
          {:ok, {:catch, target, state, return_type}}
        end

      {{:ok, name}, [target]} when name in [:if_false, :if_false8, :if_true, :if_true8] ->
        with {:ok, _cond_type, state} <- pop_type(state) do
          {:ok, {:branch, target, state, return_type}}
        end

      {{:ok, name}, [target]} when name in [:goto, :goto8, :goto16] ->
        {:ok, {:goto, target, state, return_type}}

      {{:ok, :return}, _} ->
        with {:ok, type, _state} <- pop_type(state) do
          {:ok, {:halt, join_type(return_type, type)}}
        end

      {{:ok, :return_undef}, _} ->
        {:ok, {:halt, join_type(return_type, :undefined)}}

      {{:ok, name}, _} when name in [:throw, :throw_error] ->
        {:ok, {:halt, return_type}}

      {{:ok, :nop}, _} ->
        {:ok, {:continue, state, return_type}}

      _ ->
        with {:ok, state} <- apply_generic_stack_effect(state, op, args) do
          {:ok, {:continue, state, return_type}}
        end
    end
  end

  defp transfer_unary_type(name, state, return_type) do
    with {:ok, type, state} <- pop_type(state) do
      result_type = unary_result_type(name, type)
      {:ok, {:continue, push_type(state, result_type), return_type}}
    end
  end

  defp transfer_binaryish_type(name, state, return_type) do
    with {:ok, right_type, state} <- pop_type(state),
         {:ok, left_type, state} <- pop_type(state) do
      result_type = binary_result_type(name, left_type, right_type)
      {:ok, {:continue, push_type(state, result_type), return_type}}
    end
  end

  defp initial_type_state(slot_count, stack_depth) do
    slot_types =
      if slot_count == 0,
        do: %{},
        else: Map.new(0..(slot_count - 1), fn idx -> {idx, :unknown} end)

    %{
      slot_types: slot_types,
      stack_types: List.duplicate(:unknown, stack_depth)
    }
  end

  defp merge_block_updates(entry_types, updates) do
    Enum.reduce(updates, entry_types, fn {target, state}, acc ->
      Map.update(acc, target, state, &merge_type_state(&1, state))
    end)
  end

  defp merge_type_state(left, right) do
    %{
      slot_types:
        Map.merge(left.slot_types, right.slot_types, fn _idx, left_type, right_type ->
          join_type(left_type, right_type)
        end),
      stack_types: merge_stack_types(left.stack_types, right.stack_types)
    }
  end

  defp merge_stack_types(left, right) when length(left) == length(right),
    do: Enum.zip_with(left, right, &join_type/2)

  defp merge_stack_types(left, _right), do: Enum.map(left, fn _ -> :unknown end)

  defp put_slot_type(state, idx, type),
    do: %{state | slot_types: Map.put(state.slot_types, idx, type)}

  defp slot_type(state, idx), do: Map.get(state.slot_types, idx, :unknown)
  defp push_type(state, type), do: %{state | stack_types: [type | state.stack_types]}

  defp pop_type(%{stack_types: [type | rest]} = state),
    do: {:ok, type, %{state | stack_types: rest}}

  defp pop_type(_state), do: {:error, :stack_underflow}

  defp pop_types(state, 0), do: {:ok, state}

  defp pop_types(state, count) when count > 0 do
    with {:ok, _type, state} <- pop_type(state) do
      pop_types(state, count - 1)
    end
  end

  defp apply_generic_stack_effect(state, op, args) do
    with {:ok, pop_count, push_count} <- Stack.stack_effect(op, args),
         {:ok, state} <- pop_types(state, pop_count) do
      next_state =
        if push_count == 0 do
          state
        else
          Enum.reduce(1..push_count, state, fn _, acc -> push_type(acc, :unknown) end)
        end

      {:ok, next_state}
    end
  end

  defp unary_result_type(:neg, type) when type in [:integer, :number], do: type
  defp unary_result_type(:plus, type) when type in [:integer, :number], do: type
  defp unary_result_type(:typeof, _type), do: :string
  defp unary_result_type(:delete, _type), do: :boolean
  defp unary_result_type(:not, _type), do: :integer
  defp unary_result_type(:lnot, _type), do: :boolean
  defp unary_result_type(:is_undefined, _type), do: :boolean
  defp unary_result_type(:is_null, _type), do: :boolean
  defp unary_result_type(_name, _type), do: :unknown

  defp binary_result_type(:add, :integer, :integer), do: :integer
  defp binary_result_type(:add, :string, :string), do: :string

  defp binary_result_type(:add, left, right)
       when left in [:integer, :number] and right in [:integer, :number],
       do: :number

  defp binary_result_type(name, left, right)
       when name in [:sub, :mul] and left == :integer and right == :integer,
       do: :integer

  defp binary_result_type(name, left, right)
       when name in [:sub, :mul, :div, :mod, :pow] and left in [:integer, :number] and
              right in [:integer, :number],
       do: :number

  defp binary_result_type(name, left, right)
       when name in [:lt, :lte, :gt, :gte] and left in [:integer, :number] and
              right in [:integer, :number],
       do: :boolean

  defp binary_result_type(name, _left, _right)
       when name in [
              :lt,
              :lte,
              :gt,
              :gte,
              :eq,
              :neq,
              :strict_eq,
              :strict_neq,
              :instanceof,
              :in,
              :typeof_is_undefined,
              :typeof_is_function,
              :is_undefined_or_null
            ],
       do: :boolean

  defp binary_result_type(name, _left, _right)
       when name in [:shl, :sar, :shr, :band, :bor, :bxor],
       do: :integer

  defp binary_result_type(_name, _left, _right), do: :unknown

  defp invoke_result_type(:self_fun, return_type), do: return_type
  defp invoke_result_type({:function, type}, _return_type), do: type
  defp invoke_result_type(_fun_type, _return_type), do: :unknown

  defp constant_type(constants, idx) do
    case Enum.at(constants, idx) do
      value when is_integer(value) -> :integer
      value when is_float(value) -> :number
      value when is_boolean(value) -> :boolean
      value when is_binary(value) -> :string
      nil -> :null
      :undefined -> :undefined
      %Bytecode.Function{} = fun -> function_type(fun)
      _ -> :unknown
    end
  end

  defp closure_type(constants, idx) do
    case Enum.at(constants, idx) do
      %Bytecode.Function{} = fun -> function_type(fun)
      _ -> :function
    end
  end

  defp special_object_type(2), do: :self_fun
  defp special_object_type(3), do: :function
  defp special_object_type(type) when type in [0, 1, 5, 6, 7], do: :object
  defp special_object_type(_type), do: :unknown

  defp literal_type(value) when is_integer(value), do: :integer
  defp literal_type(value) when is_float(value), do: :number
  defp literal_type(value) when is_boolean(value), do: :boolean
  defp literal_type(value) when is_binary(value), do: :string
  defp literal_type(nil), do: :null
  defp literal_type(:undefined), do: :undefined
  defp literal_type(_value), do: :unknown

  defp join_type(:unknown, other), do: other
  defp join_type(other, :unknown), do: other
  defp join_type(type, type), do: type
  defp join_type(:integer, :number), do: :number
  defp join_type(:number, :integer), do: :number
  defp join_type(:self_fun, :function), do: :function
  defp join_type(:function, :self_fun), do: :function
  defp join_type({:function, left}, {:function, right}), do: {:function, join_type(left, right)}
  defp join_type({:function, type}, :function), do: {:function, type}
  defp join_type(:function, {:function, type}), do: {:function, type}
  defp join_type(:self_fun, {:function, type}), do: {:function, type}
  defp join_type({:function, type}, :self_fun), do: {:function, type}
  defp join_type(_left, _right), do: :unknown
end
