defmodule QuickBEAM.BeamVM.Compiler do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Decoder, Opcodes}
  alias QuickBEAM.BeamVM.Compiler.{Runner, RuntimeHelpers}
  alias QuickBEAM.BeamVM.Interpreter.Values

  @line 1
  @tdz :__tdz__

  @type compiled_fun :: {module(), atom()}

  def invoke(fun, args), do: Runner.invoke(fun, args)

  def compile(%Bytecode.Function{closure_vars: []} = fun) do
    module = module_name(fun)
    entry = entry_name()

    case :code.is_loaded(module) do
      {:file, _} ->
        {:ok, {module, entry}}

      false ->
        with {:ok, instructions} <- Decoder.decode(fun.byte_code, fun.arg_count),
             {:ok, {slot_count, block_forms}} <- lower(fun, instructions),
             {:ok, _module, binary} <-
               compile_forms(module, entry, fun.arg_count, slot_count, block_forms),
             {:module, ^module} <- :code.load_binary(module, ~c"quickbeam_compiler", binary) do
          {:ok, {module, entry}}
        else
          {:error, _} = error -> error
          other -> {:error, {:load_failed, other}}
        end
    end
  end

  def compile(_), do: {:error, :closure_not_supported}

  defp lower(fun, instructions) do
    entries = block_entries(instructions)
    slot_count = fun.arg_count + fun.var_count

    with {:ok, stack_depths} <- infer_block_stack_depths(instructions, entries) do
      blocks =
        for start <- entries, Map.has_key?(stack_depths, start), into: [] do
          {start,
           block_form(
             start,
             fun.arg_count,
             slot_count,
             instructions,
             entries,
             Map.fetch!(stack_depths, start),
             stack_depths
           )}
        end

      case Enum.find(blocks, fn {_start, form} -> match?({:error, _}, form) end) do
        nil -> {:ok, {slot_count, Enum.map(blocks, &elem(&1, 1))}}
        {_start, error} -> error
      end
    end
  end

  defp block_entries(instructions) do
    entries =
      instructions
      |> Enum.with_index()
      |> Enum.reduce(MapSet.new([0]), fn {{op, args}, idx}, acc ->
        case opcode_name(op) do
          {:ok, name} when name in [:if_false, :if_false8, :if_true, :if_true8] ->
            [target] = args
            acc |> MapSet.put(target) |> MapSet.put(idx + 1)

          {:ok, name} when name in [:goto, :goto8, :goto16] ->
            [target] = args
            MapSet.put(acc, target)

          _ ->
            acc
        end
      end)

    entries
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp block_form(start, arg_count, slot_count, instructions, entries, stack_depth, stack_depths) do
    state = initial_state(slot_count, stack_depth)
    next_entry = next_entry(entries, start)
    args = slot_vars(slot_count) ++ stack_vars(stack_depth)

    with {:ok, body} <-
           lower_block(instructions, start, next_entry, arg_count, state, stack_depths) do
      {:function, @line, block_name(start), slot_count + stack_depth,
       [{:clause, @line, args, [], body}]}
    end
  end

  defp next_entry(entries, start) do
    Enum.find(entries, &(&1 > start))
  end

  defp initial_state(slot_count, stack_depth) do
    slots =
      if slot_count == 0,
        do: %{},
        else: Map.new(0..(slot_count - 1), fn idx -> {idx, slot_var(idx)} end)

    stack =
      if stack_depth == 0,
        do: [],
        else: Enum.map(0..(stack_depth - 1), &stack_var/1)

    %{
      body: [],
      slots: slots,
      stack: stack,
      temp: 0
    }
  end

  defp lower_block(instructions, idx, next_entry, arg_count, state, _stack_depths)
       when idx >= length(instructions) do
    {:error, {:missing_terminator, idx, next_entry, arg_count, state.body}}
  end

  defp lower_block(_instructions, idx, idx, _arg_count, state, stack_depths) do
    with {:ok, call} <- block_jump_call(state, idx, stack_depths) do
      {:ok, state.body ++ [call]}
    end
  end

  defp lower_block(instructions, idx, next_entry, arg_count, state, stack_depths) do
    instruction = Enum.at(instructions, idx)

    case lower_instruction(instruction, idx, next_entry, arg_count, state, stack_depths) do
      {:ok, next_state} ->
        lower_block(instructions, idx + 1, next_entry, arg_count, next_state, stack_depths)

      {:done, body} ->
        {:ok, body}

      {:error, _} = error ->
        error
    end
  end

  defp lower_instruction({op, args}, idx, next_entry, _arg_count, state, stack_depths) do
    name = opcode_name(op)

    case {name, args} do
      {{:ok, :push_i32}, [value]} ->
        {:ok, push(state, integer(value))}

      {{:ok, :push_i16}, [value]} ->
        {:ok, push(state, integer(value))}

      {{:ok, :push_i8}, [value]} ->
        {:ok, push(state, integer(value))}

      {{:ok, :push_minus1}, [_]} ->
        {:ok, push(state, integer(-1))}

      {{:ok, :push_0}, [_]} ->
        {:ok, push(state, integer(0))}

      {{:ok, :push_1}, [_]} ->
        {:ok, push(state, integer(1))}

      {{:ok, :push_2}, [_]} ->
        {:ok, push(state, integer(2))}

      {{:ok, :push_3}, [_]} ->
        {:ok, push(state, integer(3))}

      {{:ok, :push_4}, [_]} ->
        {:ok, push(state, integer(4))}

      {{:ok, :push_5}, [_]} ->
        {:ok, push(state, integer(5))}

      {{:ok, :push_6}, [_]} ->
        {:ok, push(state, integer(6))}

      {{:ok, :push_7}, [_]} ->
        {:ok, push(state, integer(7))}

      {{:ok, :push_true}, []} ->
        {:ok, push(state, atom(true))}

      {{:ok, :push_false}, []} ->
        {:ok, push(state, atom(false))}

      {{:ok, :null}, []} ->
        {:ok, push(state, atom(nil))}

      {{:ok, :undefined}, []} ->
        {:ok, push(state, atom(:undefined))}

      {{:ok, :push_empty_string}, []} ->
        {:error, {:unsupported_literal, :empty_string}}

      {{:ok, :object}, []} ->
        {:ok, push(state, compiler_call(:new_object, []))}

      {{:ok, :array_from}, [argc]} ->
        array_from_call(state, argc)

      {{:ok, :push_const}, [idx]} ->
        push_const(state, idx)

      {{:ok, :push_atom_value}, [atom_idx]} ->
        {:ok, push(state, compiler_call(:push_atom_value, [literal(atom_idx)]))}

      {{:ok, :get_var}, [atom_idx]} ->
        {:ok, push(state, compiler_call(:get_var, [literal(atom_idx)]))}

      {{:ok, :get_var_undef}, [atom_idx]} ->
        {:ok, push(state, compiler_call(:get_var_undef, [literal(atom_idx)]))}

      {{:ok, :get_arg}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_arg0}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_arg1}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_arg2}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_arg3}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc0}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc1}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc2}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc3}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc8}, [slot_idx]} ->
        {:ok, push(state, slot_expr(state, slot_idx))}

      {{:ok, :get_loc0_loc1}, [slot0, slot1]} ->
        {:ok, %{state | stack: [slot_expr(state, slot1), slot_expr(state, slot0) | state.stack]}}

      {{:ok, :get_loc_check}, [slot_idx]} ->
        {:ok,
         push(state, compiler_call(:ensure_initialized_local!, [slot_expr(state, slot_idx)]))}

      {{:ok, :set_loc_uninitialized}, [slot_idx]} ->
        {:ok, put_slot(state, slot_idx, atom(@tdz))}

      {{:ok, :put_loc}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_loc0}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_loc1}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_loc2}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_loc3}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_loc8}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_arg}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_arg0}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_arg1}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_arg2}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_arg3}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :put_loc_check}, [slot_idx]} ->
        assign_slot(state, slot_idx, false, :ensure_initialized_local!)

      {{:ok, :put_loc_check_init}, [slot_idx]} ->
        assign_slot(state, slot_idx, false)

      {{:ok, :set_loc}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_loc0}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_loc1}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_loc2}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_loc3}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_arg}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_arg0}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_arg1}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_arg2}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :set_arg3}, [slot_idx]} ->
        assign_slot(state, slot_idx, true)

      {{:ok, :dup}, []} ->
        duplicate_top(state)

      {{:ok, :dup2}, []} ->
        duplicate_top_two(state)

      {{:ok, :drop}, []} ->
        drop_top(state)

      {{:ok, :swap}, []} ->
        swap_top(state)

      {{:ok, :neg}, []} ->
        unary_local_call(state, :op_neg)

      {{:ok, :plus}, []} ->
        unary_local_call(state, :op_plus)

      {{:ok, :not}, []} ->
        unary_call(state, RuntimeHelpers, :bit_not)

      {{:ok, :lnot}, []} ->
        unary_call(state, RuntimeHelpers, :lnot)

      {{:ok, :is_undefined}, []} ->
        unary_call(state, RuntimeHelpers, :is_undefined)

      {{:ok, :is_null}, []} ->
        unary_call(state, RuntimeHelpers, :is_null)

      {{:ok, :typeof_is_undefined}, []} ->
        unary_call(state, RuntimeHelpers, :typeof_is_undefined)

      {{:ok, :typeof_is_function}, []} ->
        unary_call(state, RuntimeHelpers, :typeof_is_function)

      {{:ok, :inc}, []} ->
        unary_call(state, RuntimeHelpers, :inc)

      {{:ok, :dec}, []} ->
        unary_call(state, RuntimeHelpers, :dec)

      {{:ok, :post_inc}, []} ->
        post_update(state, :post_inc)

      {{:ok, :post_dec}, []} ->
        post_update(state, :post_dec)

      {{:ok, :add}, []} ->
        binary_local_call(state, :op_add)

      {{:ok, :sub}, []} ->
        binary_local_call(state, :op_sub)

      {{:ok, :mul}, []} ->
        binary_local_call(state, :op_mul)

      {{:ok, :div}, []} ->
        binary_local_call(state, :op_div)

      {{:ok, :mod}, []} ->
        binary_call(state, Values, :mod)

      {{:ok, :pow}, []} ->
        binary_call(state, Values, :pow)

      {{:ok, :band}, []} ->
        binary_call(state, Values, :band)

      {{:ok, :bor}, []} ->
        binary_call(state, Values, :bor)

      {{:ok, :bxor}, []} ->
        binary_call(state, Values, :bxor)

      {{:ok, :shl}, []} ->
        binary_call(state, Values, :shl)

      {{:ok, :sar}, []} ->
        binary_call(state, Values, :sar)

      {{:ok, :shr}, []} ->
        binary_call(state, Values, :shr)

      {{:ok, :typeof}, []} ->
        unary_call(state, Values, :typeof)

      {{:ok, :instanceof}, []} ->
        binary_call(state, RuntimeHelpers, :instanceof)

      {{:ok, :in}, []} ->
        in_call(state)

      {{:ok, :delete}, []} ->
        delete_call(state)

      {{:ok, :get_length}, []} ->
        unary_call(state, RuntimeHelpers, :get_length)

      {{:ok, :get_array_el}, []} ->
        binary_call(state, QuickBEAM.BeamVM.Interpreter.Objects, :get_element)

      {{:ok, :get_field}, [atom_idx]} ->
        unary_call(state, RuntimeHelpers, :get_field, [literal(atom_idx)])

      {{:ok, :get_field2}, [atom_idx]} ->
        get_field2(state, atom_idx)

      {{:ok, :put_field}, [atom_idx]} ->
        put_field_call(state, atom_idx)

      {{:ok, :define_field}, [atom_idx]} ->
        define_field_call(state, atom_idx)

      {{:ok, :put_array_el}, []} ->
        put_array_el_call(state)

      {{:ok, :append}, []} ->
        append_call(state)

      {{:ok, :copy_data_properties}, [mask]} ->
        copy_data_properties_call(state, mask)

      {{:ok, :to_propkey}, []} ->
        {:ok, state}

      {{:ok, :to_propkey2}, []} ->
        {:ok, state}

      {{:ok, :lt}, []} ->
        binary_local_call(state, :op_lt)

      {{:ok, :lte}, []} ->
        binary_local_call(state, :op_lte)

      {{:ok, :gt}, []} ->
        binary_local_call(state, :op_gt)

      {{:ok, :gte}, []} ->
        binary_local_call(state, :op_gte)

      {{:ok, :eq}, []} ->
        binary_local_call(state, :op_eq)

      {{:ok, :neq}, []} ->
        binary_local_call(state, :op_neq)

      {{:ok, :strict_eq}, []} ->
        binary_local_call(state, :op_strict_eq)

      {{:ok, :strict_neq}, []} ->
        binary_local_call(state, :op_strict_neq)

      {{:ok, :call_constructor}, [argc]} ->
        invoke_constructor_call(state, argc)

      {{:ok, :call}, [argc]} ->
        invoke_call(state, argc)

      {{:ok, :call0}, [argc]} ->
        invoke_call(state, argc)

      {{:ok, :call1}, [argc]} ->
        invoke_call(state, argc)

      {{:ok, :call2}, [argc]} ->
        invoke_call(state, argc)

      {{:ok, :call3}, [argc]} ->
        invoke_call(state, argc)

      {{:ok, :tail_call}, [argc]} ->
        invoke_tail_call(state, argc)

      {{:ok, :call_method}, [argc]} ->
        invoke_method_call(state, argc)

      {{:ok, :tail_call_method}, [argc]} ->
        invoke_tail_method_call(state, argc)

      {{:ok, :is_undefined_or_null}, []} ->
        unary_call(state, RuntimeHelpers, :is_undefined_or_null)

      {{:ok, :if_false}, [target]} ->
        branch(state, idx, next_entry, target, false, stack_depths)

      {{:ok, :if_false8}, [target]} ->
        branch(state, idx, next_entry, target, false, stack_depths)

      {{:ok, :if_true}, [target]} ->
        branch(state, idx, next_entry, target, true, stack_depths)

      {{:ok, :if_true8}, [target]} ->
        branch(state, idx, next_entry, target, true, stack_depths)

      {{:ok, :goto}, [target]} ->
        goto(state, target, stack_depths)

      {{:ok, :goto8}, [target]} ->
        goto(state, target, stack_depths)

      {{:ok, :goto16}, [target]} ->
        goto(state, target, stack_depths)

      {{:ok, :return}, []} ->
        return_top(state)

      {{:ok, :return_undef}, []} ->
        {:done, state.body ++ [atom(:undefined)]}

      {{:ok, :nop}, []} ->
        {:ok, state}

      {{:error, _} = error, _} ->
        error

      {{:ok, name}, _} ->
        {:error, {:unsupported_opcode, name}}
    end
  end

  defp push_const(_state, idx), do: {:error, {:unsupported_const, idx}}

  defp assign_slot(state, idx, keep?, wrapper \\ nil) do
    with {:ok, expr, state} <- pop(state) do
      expr = if wrapper, do: compiler_call(wrapper, [expr]), else: expr
      {bound, state} = bind(state, slot_name(idx, state.temp), expr)
      state = put_slot(state, idx, bound)
      state = if keep?, do: push(state, bound), else: state
      {:ok, state}
    end
  end

  defp duplicate_top(state) do
    with {:ok, expr, state} <- pop(state) do
      {bound, state} = bind(state, temp_name(state.temp), expr)
      {:ok, %{state | stack: [bound, bound | state.stack]}}
    end
  end

  defp duplicate_top_two(state) do
    with {:ok, first, state} <- pop(state),
         {:ok, second, state} <- pop(state) do
      {second_bound, state} = bind(state, temp_name(state.temp), second)
      {first_bound, state} = bind(state, temp_name(state.temp), first)

      {:ok,
       %{state | stack: [first_bound, second_bound, first_bound, second_bound | state.stack]}}
    end
  end

  defp drop_top(state) do
    case state.stack do
      [_ | rest] -> {:ok, %{state | stack: rest}}
      [] -> {:error, :stack_underflow}
    end
  end

  defp swap_top(%{stack: [a, b | rest]} = state), do: {:ok, %{state | stack: [b, a | rest]}}
  defp swap_top(_state), do: {:error, :stack_underflow}

  defp post_update(state, fun) do
    with {:ok, expr, state} <- pop(state) do
      {pair, state} = bind(state, temp_name(state.temp), compiler_call(fun, [expr]))
      {:ok, %{state | stack: [tuple_element(pair, 1), tuple_element(pair, 2) | state.stack]}}
    end
  end

  defp unary_call(state, mod, fun, extra_args \\ []) do
    with {:ok, expr, state} <- pop(state) do
      {:ok, push(state, remote_call(mod, fun, [expr | extra_args]))}
    end
  end

  defp effectful_push(state, expr) do
    {bound, state} = bind(state, temp_name(state.temp), expr)
    {:ok, push(state, bound)}
  end

  defp unary_local_call(state, fun) do
    with {:ok, expr, state} <- pop(state) do
      {:ok, push(state, local_call(fun, [expr]))}
    end
  end

  defp binary_call(state, mod, fun) do
    with {:ok, right, state} <- pop(state),
         {:ok, left, state} <- pop(state) do
      {:ok, push(state, remote_call(mod, fun, [left, right]))}
    end
  end

  defp binary_local_call(state, fun) do
    with {:ok, right, state} <- pop(state),
         {:ok, left, state} <- pop(state) do
      {:ok, push(state, local_call(fun, [left, right]))}
    end
  end

  defp get_field2(state, atom_idx) do
    with {:ok, obj, state} <- pop(state) do
      field = remote_call(RuntimeHelpers, :get_field, [obj, literal(atom_idx)])
      {:ok, %{state | stack: [field, obj | state.stack]}}
    end
  end

  defp put_field_call(state, atom_idx) do
    with {:ok, val, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      {:ok,
       %{state | body: state.body ++ [compiler_call(:put_field, [obj, literal(atom_idx), val])]}}
    end
  end

  defp define_field_call(state, atom_idx) do
    with {:ok, val, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      {:ok, push(state, compiler_call(:define_field, [obj, literal(atom_idx), val]))}
    end
  end

  defp put_array_el_call(state) do
    with {:ok, val, state} <- pop(state),
         {:ok, idx, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      {:ok, %{state | body: state.body ++ [compiler_call(:put_array_el, [obj, idx, val])]}}
    end
  end

  defp invoke_call(state, argc) do
    with {:ok, args, state} <- pop_n(state, argc),
         {:ok, fun, state} <- pop(state) do
      effectful_push(state, compiler_call(:invoke_runtime, [fun, list_expr(Enum.reverse(args))]))
    end
  end

  defp invoke_constructor_call(state, argc) do
    with {:ok, args, state} <- pop_n(state, argc),
         {:ok, new_target, state} <- pop(state),
         {:ok, ctor, state} <- pop(state) do
      effectful_push(
        state,
        compiler_call(:construct_runtime, [ctor, new_target, list_expr(Enum.reverse(args))])
      )
    end
  end

  defp invoke_tail_call(state, argc) do
    with {:ok, args, state} <- pop_n(state, argc),
         {:ok, fun, %{stack: []} = state} <- pop(state) do
      {:done,
       state.body ++ [compiler_call(:invoke_runtime, [fun, list_expr(Enum.reverse(args))])]}
    else
      {:ok, _fun, _state} -> {:error, :stack_not_empty_on_tail_call}
      {:error, _} = error -> error
    end
  end

  defp invoke_method_call(state, argc) do
    with {:ok, args, state} <- pop_n(state, argc),
         {:ok, fun, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      effectful_push(
        state,
        compiler_call(:invoke_method_runtime, [fun, obj, list_expr(Enum.reverse(args))])
      )
    end
  end

  defp array_from_call(state, argc) do
    with {:ok, elems, state} <- pop_n(state, argc) do
      {:ok, push(state, compiler_call(:array_from, [list_expr(Enum.reverse(elems))]))}
    end
  end

  defp in_call(state) do
    with {:ok, obj, state} <- pop(state),
         {:ok, key, state} <- pop(state) do
      {:ok,
       push(state, remote_call(QuickBEAM.BeamVM.Interpreter.Objects, :has_property, [obj, key]))}
    end
  end

  defp append_call(state) do
    with {:ok, obj, state} <- pop(state),
         {:ok, idx, state} <- pop(state),
         {:ok, arr, state} <- pop(state) do
      {pair, state} =
        bind(state, temp_name(state.temp), compiler_call(:append_spread, [arr, idx, obj]))

      {:ok, %{state | stack: [tuple_element(pair, 1), tuple_element(pair, 2) | state.stack]}}
    end
  end

  defp copy_data_properties_call(state, mask) do
    target_idx = Bitwise.band(mask, 3)
    source_idx = Bitwise.band(Bitwise.bsr(mask, 2), 7)

    with {:ok, state, target} <- bind_stack_entry(state, target_idx),
         {:ok, state, source} <- bind_stack_entry(state, source_idx) do
      {:ok,
       %{state | body: state.body ++ [compiler_call(:copy_data_properties, [target, source])]}}
    else
      :error -> {:error, {:copy_data_properties_missing, mask, target_idx, source_idx}}
    end
  end

  defp delete_call(state) do
    with {:ok, key, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      effectful_push(state, compiler_call(:delete_property, [obj, key]))
    end
  end

  defp invoke_tail_method_call(state, argc) do
    with {:ok, args, state} <- pop_n(state, argc),
         {:ok, fun, state} <- pop(state),
         {:ok, obj, %{stack: []} = state} <- pop(state) do
      {:done,
       state.body ++
         [compiler_call(:invoke_method_runtime, [fun, obj, list_expr(Enum.reverse(args))])]}
    else
      {:ok, _obj, _state} -> {:error, :stack_not_empty_on_tail_call}
      {:error, _} = error -> error
    end
  end

  defp goto(state, target, stack_depths) do
    with {:ok, call} <- block_jump_call(state, target, stack_depths) do
      {:done, state.body ++ [call]}
    end
  end

  defp branch(%{stack: stack}, idx, next_entry, target, sense, _stack_depths) when stack == [] do
    {:error, {:missing_branch_condition, idx, target, sense, next_entry}}
  end

  defp branch(state, _idx, next_entry, target, sense, _stack_depths) when is_nil(next_entry) do
    {:error, {:missing_fallthrough_block, target, sense, state.body}}
  end

  defp branch(state, _idx, next_entry, target, sense, stack_depths) do
    with {:ok, cond_expr, state} <- pop(state),
         {:ok, target_call} <- block_jump_call(state, target, stack_depths),
         {:ok, next_call} <- block_jump_call(state, next_entry, stack_depths) do
      truthy = remote_call(Values, :truthy?, [cond_expr])
      false_body = [target_call]
      true_body = [next_call]

      body =
        case sense do
          false -> state.body ++ [case_expr(truthy, false_body, true_body)]
          true -> state.body ++ [case_expr(truthy, true_body, false_body)]
        end

      {:done, body}
    end
  end

  defp return_top(state) do
    with {:ok, expr, %{stack: []}} <- pop(state) do
      {:done, state.body ++ [expr]}
    else
      {:ok, _expr, _state} -> {:error, :stack_not_empty_on_return}
      {:error, _} = error -> error
    end
  end

  defp pop(%{stack: [expr | rest]} = state), do: {:ok, expr, %{state | stack: rest}}
  defp pop(_state), do: {:error, :stack_underflow}

  defp pop_n(state, 0), do: {:ok, [], state}

  defp pop_n(state, count) when count > 0 do
    with {:ok, expr, state} <- pop(state),
         {:ok, rest, state} <- pop_n(state, count - 1) do
      {:ok, [expr | rest], state}
    end
  end

  defp push(state, expr), do: %{state | stack: [expr | state.stack]}

  defp bind_stack_entry(state, idx) do
    case Enum.fetch(state.stack, idx) do
      {:ok, expr} ->
        {bound, state} = bind(state, temp_name(state.temp), expr)
        {:ok, %{state | stack: List.replace_at(state.stack, idx, bound)}, bound}

      :error ->
        :error
    end
  end

  defp put_slot(state, idx, expr), do: %{state | slots: Map.put(state.slots, idx, expr)}

  defp slot_expr(state, idx), do: Map.get(state.slots, idx, atom(:undefined))

  defp infer_block_stack_depths(instructions, entries) do
    walk_block_stack_depths(instructions, entries, [{0, 0}], %{})
  end

  defp walk_block_stack_depths(_instructions, _entries, [], depths), do: {:ok, depths}

  defp walk_block_stack_depths(instructions, entries, [{start, depth} | rest], depths) do
    case Map.fetch(depths, start) do
      {:ok, ^depth} ->
        walk_block_stack_depths(instructions, entries, rest, depths)

      {:ok, other_depth} ->
        {:error, {:inconsistent_block_stack_depth, start, other_depth, depth}}

      :error ->
        with {:ok, successors} <- simulate_block_stack_depths(instructions, entries, start, depth) do
          walk_block_stack_depths(
            instructions,
            entries,
            rest ++ successors,
            Map.put(depths, start, depth)
          )
        end
    end
  end

  defp simulate_block_stack_depths(instructions, entries, start, depth) do
    next_entry = next_entry(entries, start)
    do_simulate_block_stack_depths(instructions, start, next_entry, depth)
  end

  defp do_simulate_block_stack_depths(instructions, idx, _next_entry, _depth)
       when idx >= length(instructions) do
    {:error, {:missing_terminator, idx}}
  end

  defp do_simulate_block_stack_depths(_instructions, idx, idx, depth), do: {:ok, [{idx, depth}]}

  defp do_simulate_block_stack_depths(instructions, idx, next_entry, depth) do
    {op, args} = Enum.at(instructions, idx)

    with {:ok, next_depth} <- apply_stack_effect(op, args, depth) do
      case {opcode_name(op), args} do
        {{:ok, name}, [target]} when name in [:if_false, :if_false8, :if_true, :if_true8] ->
          if is_nil(next_entry) do
            {:error, {:missing_fallthrough_block, target, name}}
          else
            {:ok, [{target, next_depth}, {next_entry, next_depth}]}
          end

        {{:ok, name}, [target]} when name in [:goto, :goto8, :goto16] ->
          {:ok, [{target, next_depth}]}

        {{:ok, name}, [_argc]} when name in [:tail_call, :tail_call_method] ->
          {:ok, []}

        {{:ok, :return}, []} ->
          {:ok, []}

        {{:ok, :return_undef}, []} ->
          {:ok, []}

        _ ->
          do_simulate_block_stack_depths(instructions, idx + 1, next_entry, next_depth)
      end
    end
  end

  defp apply_stack_effect(op, args, depth) do
    with {:ok, pop_count, push_count} <- stack_effect(op, args),
         true <- depth >= pop_count or {:error, {:stack_underflow_at, op, args, depth, pop_count}} do
      {:ok, depth - pop_count + push_count}
    end
  end

  defp stack_effect(op, args) do
    case {opcode_name(op), args} do
      {{:ok, name}, [argc]} when name in [:call, :call0, :call1, :call2, :call3, :tail_call] ->
        {:ok, argc + 1, if(name == :tail_call, do: 0, else: 1)}

      {{:ok, name}, [argc]} when name in [:call_method, :tail_call_method] ->
        {:ok, argc + 2, if(name == :tail_call_method, do: 0, else: 1)}

      {{:ok, :array_from}, [argc]} ->
        {:ok, argc, 1}

      {{:ok, _name}, _} ->
        case Opcodes.info(op) do
          {_name, _size, pop_count, push_count, _fmt} -> {:ok, pop_count, push_count}
          nil -> {:error, {:unknown_opcode, op}}
        end

      {{:error, _} = error, _} ->
        error
    end
  end

  defp bind(state, name, expr) do
    var = var(name)
    {var, %{state | body: state.body ++ [match(var, expr)], temp: state.temp + 1}}
  end

  defp compile_forms(module, entry, arity, slot_count, block_forms) do
    forms = [
      {:attribute, @line, :module, module},
      {:attribute, @line, :export, [{entry, arity}]},
      entry_form(entry, arity, slot_count)
      | helper_forms() ++ block_forms
    ]

    case :compile.forms(forms, [:binary, :return_errors, :return_warnings]) do
      {:ok, mod, binary} -> {:ok, mod, binary}
      {:ok, mod, binary, _warnings} -> {:ok, mod, binary}
      {:error, errors, _warnings} -> {:error, {:compile_failed, errors}}
    end
  end

  defp entry_form(entry, arity, slot_count) do
    args = slot_vars(arity)

    locals =
      if slot_count <= arity,
        do: [],
        else: Enum.map(arity..(slot_count - 1), fn _ -> atom(:undefined) end)

    body = [
      local_call(block_name(0), args ++ locals)
    ]

    {:function, @line, entry, arity, [{:clause, @line, args, [], body}]}
  end

  defp current_slots(state), do: ordered_slot_values(state.slots)
  defp current_stack(state), do: state.stack

  defp block_jump_call(state, target, stack_depths) do
    expected_depth = Map.get(stack_depths, target)
    actual_depth = length(state.stack)

    cond do
      is_nil(expected_depth) ->
        {:error, {:unknown_block_target, target}}

      expected_depth != actual_depth ->
        {:error, {:stack_depth_mismatch, target, expected_depth, actual_depth}}

      true ->
        {:ok, local_call(block_name(target), current_slots(state) ++ current_stack(state))}
    end
  end

  defp helper_forms do
    [
      guarded_binary_helper(:op_add, :+, Values, :add),
      guarded_binary_helper(:op_sub, :-, Values, :sub),
      guarded_binary_helper(:op_mul, :*, Values, :mul),
      guarded_binary_helper(:op_div, :/, Values, :div),
      guarded_binary_helper(:op_lt, :<, Values, :lt),
      guarded_binary_helper(:op_lte, :"=<", Values, :lte),
      guarded_binary_helper(:op_gt, :>, Values, :gt),
      guarded_binary_helper(:op_gte, :>=, Values, :gte),
      eq_helper(),
      neq_helper(),
      strict_eq_helper(),
      strict_neq_helper(),
      guarded_unary_helper(:op_neg, :-, Values, :neg),
      unary_fallback_helper(:op_plus, Values, :to_number)
    ]
  end

  defp guarded_binary_helper(name, op, fallback_mod, fallback_fun) do
    a = var("A")
    b = var("B")

    {:function, @line, name, 2,
     [
       {:clause, @line, [a, b], [integer_guards(a, b)], [{:op, @line, op, a, b}]},
       {:clause, @line, [a, b], [], [remote_call(fallback_mod, fallback_fun, [a, b])]}
     ]}
  end

  defp guarded_unary_helper(name, op, fallback_mod, fallback_fun) do
    a = var("A")

    {:function, @line, name, 1,
     [
       {:clause, @line, [a], [[integer_guard(a)]], [{:op, @line, op, a}]},
       {:clause, @line, [a], [], [remote_call(fallback_mod, fallback_fun, [a])]}
     ]}
  end

  defp unary_fallback_helper(name, fallback_mod, fallback_fun) do
    a = var("A")

    {:function, @line, name, 1,
     [
       {:clause, @line, [a], [[integer_guard(a)]], [a]},
       {:clause, @line, [a], [], [remote_call(fallback_mod, fallback_fun, [a])]}
     ]}
  end

  defp eq_helper do
    a = var("A")
    b = var("B")

    {:function, @line, :op_eq, 2,
     [
       {:clause, @line, [a, b], [number_guards(a, b)], [{:op, @line, :==, a, b}]},
       {:clause, @line, [a, b], [], [remote_call(Values, :eq, [a, b])]}
     ]}
  end

  defp neq_helper do
    a = var("A")
    b = var("B")

    {:function, @line, :op_neq, 2,
     [
       {:clause, @line, [a, b], [], [{:op, @line, :not, local_call(:op_eq, [a, b])}]}
     ]}
  end

  defp strict_eq_helper do
    a = var("A")
    b = var("B")

    {:function, @line, :op_strict_eq, 2,
     [
       {:clause, @line, [a, b], [number_guards(a, b)], [{:op, @line, :==, a, b}]},
       {:clause, @line, [a, b], [], [remote_call(Values, :strict_eq, [a, b])]}
     ]}
  end

  defp strict_neq_helper do
    a = var("A")
    b = var("B")

    {:function, @line, :op_strict_neq, 2,
     [
       {:clause, @line, [a, b], [], [{:op, @line, :not, local_call(:op_strict_eq, [a, b])}]}
     ]}
  end

  defp integer_guards(a, b), do: [integer_guard(a), integer_guard(b)]
  defp number_guards(a, b), do: [number_guard(a), number_guard(b)]

  defp integer_guard(expr), do: {:call, @line, {:atom, @line, :is_integer}, [expr]}
  defp number_guard(expr), do: {:call, @line, {:atom, @line, :is_number}, [expr]}

  defp ordered_slot_values(slots) do
    slots
    |> Enum.sort_by(fn {idx, _expr} -> idx end)
    |> Enum.map(fn {_idx, expr} -> expr end)
  end

  defp case_expr(expr, false_body, true_body) do
    {:case, @line, expr,
     [
       {:clause, @line, [atom(false)], [], false_body},
       {:clause, @line, [atom(true)], [], true_body}
     ]}
  end

  defp opcode_name(op) do
    case Opcodes.info(op) do
      {name, _size, _pop, _push, _fmt} -> {:ok, name}
      nil -> {:error, {:unknown_opcode, op}}
    end
  end

  defp module_name(fun) do
    hash =
      :crypto.hash(:sha256, [fun.byte_code, <<fun.arg_count::32, fun.var_count::32>>])
      |> binary_part(0, 8)
      |> Base.encode16(case: :lower)

    Module.concat(QuickBEAM.BeamVM.Compiled, "F#{hash}")
  end

  defp entry_name, do: :run

  defp block_name(idx), do: String.to_atom("block_#{idx}")
  defp slot_name(idx, n), do: "Slot#{idx}_#{n}"
  defp temp_name(n), do: "Tmp#{n}"

  defp slot_var(idx), do: var("Slot#{idx}")
  defp stack_var(idx), do: var("Stack#{idx}")

  defp slot_vars(0), do: []
  defp slot_vars(count), do: Enum.map(0..(count - 1), &slot_var/1)

  defp stack_vars(0), do: []
  defp stack_vars(count), do: Enum.map(0..(count - 1), &stack_var/1)

  defp var(name) when is_binary(name), do: {:var, @line, String.to_atom(name)}
  defp var(name) when is_integer(name), do: {:var, @line, String.to_atom(Integer.to_string(name))}
  defp var(name) when is_atom(name), do: {:var, @line, name}

  defp integer(value), do: {:integer, @line, value}
  defp atom(value), do: {:atom, @line, value}
  defp literal(value), do: :erl_parse.abstract(value)
  defp match(left, right), do: {:match, @line, left, right}

  defp tuple_element(tuple, index) do
    {:call, @line, {:remote, @line, {:atom, @line, :erlang}, {:atom, @line, :element}},
     [integer(index), tuple]}
  end

  defp list_expr([]), do: {nil, @line}
  defp list_expr([head | tail]), do: {:cons, @line, head, list_expr(tail)}

  defp remote_call(mod, fun, args) do
    {:call, @line, {:remote, @line, {:atom, @line, mod}, {:atom, @line, fun}}, args}
  end

  defp local_call(fun, args), do: {:call, @line, {:atom, @line, fun}, args}

  defp compiler_call(fun, args), do: remote_call(RuntimeHelpers, fun, args)
end
