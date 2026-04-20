defmodule QuickBEAM.BeamVM.Compiler do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Decoder, Heap, Opcodes}
  alias QuickBEAM.BeamVM.Interpreter.Values
  alias QuickBEAM.BeamVM.Runtime.Property

  @line 1
  @tdz :__tdz__

  @type compiled_fun :: {module(), atom()}

  def invoke(%Bytecode.Function{closure_vars: []} = fun, args) do
    key = {fun.byte_code, fun.arg_count}

    case Heap.get_compiled(key) do
      {:compiled, {mod, name}} -> {:ok, apply(mod, name, args)}
      :unsupported -> :error
      nil -> compile_and_invoke(fun, args, key)
    end
  end

  def invoke(_, _), do: :error

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

  def ensure_initialized_local!(val) do
    if val == @tdz do
      throw(
        {:js_throw,
         Heap.make_error("Cannot access variable before initialization", "ReferenceError")}
      )
    end

    val
  end

  def strict_neq(a, b), do: not Values.strict_eq(a, b)

  def get_length(obj) do
    case obj do
      {:obj, ref} ->
        case Heap.get_obj(ref) do
          {:qb_arr, arr} -> :array.size(arr)
          list when is_list(list) -> length(list)
          map when is_map(map) -> Map.get(map, "length", map_size(map))
          _ -> 0
        end

      {:qb_arr, arr} ->
        :array.size(arr)

      list when is_list(list) ->
        length(list)

      s when is_binary(s) ->
        Property.string_length(s)

      %Bytecode.Function{} = fun ->
        fun.defined_arg_count

      {:closure, _, %Bytecode.Function{} = fun} ->
        fun.defined_arg_count

      {:bound, len, _, _, _} ->
        len

      _ ->
        :undefined
    end
  end

  defp compile_and_invoke(fun, args, key) do
    case compile(fun) do
      {:ok, compiled} ->
        Heap.put_compiled(key, {:compiled, compiled})
        {:ok, apply_compiled(compiled, args)}

      {:error, _} ->
        Heap.put_compiled(key, :unsupported)
        :error
    end
  end

  defp apply_compiled({mod, name}, args), do: apply(mod, name, args)

  defp lower(fun, instructions) do
    entries = block_entries(instructions)
    slot_count = fun.arg_count + fun.var_count

    blocks =
      for start <- entries, into: [] do
        {start, block_form(start, fun.arg_count, slot_count, instructions, entries)}
      end

    case Enum.find(blocks, fn {_start, form} -> match?({:error, _}, form) end) do
      nil -> {:ok, {slot_count, Enum.map(blocks, &elem(&1, 1))}}
      {_start, error} -> error
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

  defp block_form(start, arg_count, slot_count, instructions, entries) do
    state = initial_state(slot_count)
    next_entry = next_entry(entries, start)

    with {:ok, body} <- lower_block(instructions, start, next_entry, arg_count, state) do
      {:function, @line, block_name(start), slot_count,
       [{:clause, @line, slot_vars(slot_count), [], body}]}
    end
  end

  defp next_entry(entries, start) do
    Enum.find(entries, &(&1 > start))
  end

  defp initial_state(slot_count) do
    slots =
      if slot_count == 0,
        do: %{},
        else: Map.new(0..(slot_count - 1), fn idx -> {idx, slot_var(idx)} end)

    %{
      body: [],
      slots: slots,
      stack: [],
      temp: 0
    }
  end

  defp lower_block(instructions, idx, next_entry, arg_count, state)
       when idx >= length(instructions) do
    {:error, {:missing_terminator, idx, next_entry, arg_count, state.body}}
  end

  defp lower_block(_instructions, idx, idx, _arg_count, %{stack: []} = state) do
    {:ok, state.body ++ [local_call(block_name(idx), current_slots(state))]}
  end

  defp lower_block(_instructions, idx, idx, _arg_count, _state) do
    {:error, {:stack_not_empty_at_block_boundary, idx}}
  end

  defp lower_block(instructions, idx, next_entry, arg_count, state) do
    instruction = Enum.at(instructions, idx)

    case lower_instruction(instruction, idx, next_entry, arg_count, state) do
      {:ok, next_state} -> lower_block(instructions, idx + 1, next_entry, arg_count, next_state)
      {:done, body} -> {:ok, body}
      {:error, _} = error -> error
    end
  end

  defp lower_instruction({op, args}, idx, next_entry, _arg_count, state) do
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

      {{:ok, :push_const}, [idx]} ->
        push_const(state, idx)

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

      {{:ok, :drop}, []} ->
        drop_top(state)

      {{:ok, :neg}, []} ->
        unary_call(state, Values, :neg)

      {{:ok, :plus}, []} ->
        unary_call(state, Values, :to_number)

      {{:ok, :add}, []} ->
        binary_call(state, Values, :add)

      {{:ok, :sub}, []} ->
        binary_call(state, Values, :sub)

      {{:ok, :mul}, []} ->
        binary_call(state, Values, :mul)

      {{:ok, :div}, []} ->
        binary_call(state, Values, :div)

      {{:ok, :get_length}, []} ->
        unary_call(state, __MODULE__, :get_length)

      {{:ok, :get_array_el}, []} ->
        binary_call(state, QuickBEAM.BeamVM.Interpreter.Objects, :get_element)

      {{:ok, :lt}, []} ->
        binary_call(state, Values, :lt)

      {{:ok, :lte}, []} ->
        binary_call(state, Values, :lte)

      {{:ok, :gt}, []} ->
        binary_call(state, Values, :gt)

      {{:ok, :gte}, []} ->
        binary_call(state, Values, :gte)

      {{:ok, :strict_eq}, []} ->
        binary_call(state, Values, :strict_eq)

      {{:ok, :strict_neq}, []} ->
        binary_call(state, __MODULE__, :strict_neq)

      {{:ok, :if_false}, [target]} ->
        branch(state, idx, next_entry, target, false)

      {{:ok, :if_false8}, [target]} ->
        branch(state, idx, next_entry, target, false)

      {{:ok, :if_true}, [target]} ->
        branch(state, idx, next_entry, target, true)

      {{:ok, :if_true8}, [target]} ->
        branch(state, idx, next_entry, target, true)

      {{:ok, :goto}, [target]} ->
        goto(state, target)

      {{:ok, :goto8}, [target]} ->
        goto(state, target)

      {{:ok, :goto16}, [target]} ->
        goto(state, target)

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

  defp drop_top(state) do
    case state.stack do
      [_ | rest] -> {:ok, %{state | stack: rest}}
      [] -> {:error, :stack_underflow}
    end
  end

  defp unary_call(state, mod, fun) do
    with {:ok, expr, state} <- pop(state) do
      {:ok, push(state, remote_call(mod, fun, [expr]))}
    end
  end

  defp binary_call(state, mod, fun) do
    with {:ok, right, state} <- pop(state),
         {:ok, left, state} <- pop(state) do
      {:ok, push(state, remote_call(mod, fun, [left, right]))}
    end
  end

  defp goto(%{stack: []} = state, target) do
    {:done, state.body ++ [local_call(block_name(target), current_slots(state))]}
  end

  defp goto(_state, target), do: {:error, {:stack_not_empty_at_goto, target}}

  defp branch(%{stack: stack}, idx, next_entry, target, sense) when stack == [] do
    {:error, {:missing_branch_condition, idx, target, sense, next_entry}}
  end

  defp branch(state, _idx, next_entry, target, sense) when is_nil(next_entry) do
    {:error, {:missing_fallthrough_block, target, sense, state.body}}
  end

  defp branch(state, _idx, next_entry, target, sense) do
    with {:ok, cond_expr, %{stack: []} = state} <- pop(state) do
      truthy = remote_call(Values, :truthy?, [cond_expr])
      false_body = [local_call(block_name(target), current_slots(state))]
      true_body = [local_call(block_name(next_entry), current_slots(state))]

      body =
        case sense do
          false -> state.body ++ [case_expr(truthy, false_body, true_body)]
          true -> state.body ++ [case_expr(truthy, true_body, false_body)]
        end

      {:done, body}
    else
      {:ok, _cond, _state} -> {:error, {:stack_not_empty_after_branch, target}}
      {:error, _} = error -> error
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

  defp push(state, expr), do: %{state | stack: [expr | state.stack]}

  defp put_slot(state, idx, expr), do: %{state | slots: Map.put(state.slots, idx, expr)}

  defp slot_expr(state, idx), do: Map.get(state.slots, idx, atom(:undefined))

  defp bind(state, name, expr) do
    var = var(name)
    {var, %{state | body: state.body ++ [match(var, expr)], temp: state.temp + 1}}
  end

  defp compile_forms(module, entry, arity, slot_count, block_forms) do
    forms = [
      {:attribute, @line, :module, module},
      {:attribute, @line, :export, [{entry, arity}]},
      entry_form(entry, arity, slot_count)
      | block_forms
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

  defp slot_vars(0), do: []
  defp slot_vars(count), do: Enum.map(0..(count - 1), &slot_var/1)

  defp var(name) when is_binary(name), do: {:var, @line, String.to_atom(name)}
  defp var(name) when is_integer(name), do: {:var, @line, String.to_atom(Integer.to_string(name))}
  defp var(name) when is_atom(name), do: {:var, @line, name}

  defp integer(value), do: {:integer, @line, value}
  defp atom(value), do: {:atom, @line, value}
  defp match(left, right), do: {:match, @line, left, right}

  defp remote_call(mod, fun, args) do
    {:call, @line, {:remote, @line, {:atom, @line, mod}, {:atom, @line, fun}}, args}
  end

  defp local_call(fun, args), do: {:call, @line, {:atom, @line, fun}, args}

  defp compiler_call(fun, args), do: remote_call(__MODULE__, fun, args)
end
