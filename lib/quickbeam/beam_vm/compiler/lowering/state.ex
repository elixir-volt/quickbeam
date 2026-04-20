defmodule QuickBEAM.BeamVM.Compiler.Lowering.State do
  @moduledoc false

  alias QuickBEAM.BeamVM.Compiler.RuntimeHelpers
  alias QuickBEAM.BeamVM.Interpreter.Values

  @line 1

  def new(slot_count, stack_depth) do
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

  def push(state, expr), do: %{state | stack: [expr | state.stack]}

  def pop(%{stack: [expr | rest]} = state), do: {:ok, expr, %{state | stack: rest}}
  def pop(_state), do: {:error, :stack_underflow}

  def pop_n(state, 0), do: {:ok, [], state}

  def pop_n(state, count) when count > 0 do
    with {:ok, expr, state} <- pop(state),
         {:ok, rest, state} <- pop_n(state, count - 1) do
      {:ok, [expr | rest], state}
    end
  end

  def put_slot(state, idx, expr), do: %{state | slots: Map.put(state.slots, idx, expr)}
  def slot_expr(state, idx), do: Map.get(state.slots, idx, atom(:undefined))

  def bind_stack_entry(state, idx) do
    case Enum.fetch(state.stack, idx) do
      {:ok, expr} ->
        {bound, state} = bind(state, temp_name(state.temp), expr)
        {:ok, %{state | stack: List.replace_at(state.stack, idx, bound)}, bound}

      :error ->
        :error
    end
  end

  def assign_slot(state, idx, keep?, wrapper \\ nil) do
    with {:ok, expr, state} <- pop(state) do
      expr = if wrapper, do: compiler_call(wrapper, [expr]), else: expr
      {bound, state} = bind(state, slot_name(idx, state.temp), expr)
      state = put_slot(state, idx, bound)
      state = if keep?, do: push(state, bound), else: state
      {:ok, state}
    end
  end

  def duplicate_top(state) do
    with {:ok, expr, state} <- pop(state) do
      {bound, state} = bind(state, temp_name(state.temp), expr)
      {:ok, %{state | stack: [bound, bound | state.stack]}}
    end
  end

  def duplicate_top_two(state) do
    with {:ok, first, state} <- pop(state),
         {:ok, second, state} <- pop(state) do
      {second_bound, state} = bind(state, temp_name(state.temp), second)
      {first_bound, state} = bind(state, temp_name(state.temp), first)

      {:ok,
       %{state | stack: [first_bound, second_bound, first_bound, second_bound | state.stack]}}
    end
  end

  def drop_top(%{stack: [_ | rest]} = state), do: {:ok, %{state | stack: rest}}
  def drop_top(_state), do: {:error, :stack_underflow}

  def swap_top(%{stack: [a, b | rest]} = state), do: {:ok, %{state | stack: [b, a | rest]}}
  def swap_top(_state), do: {:error, :stack_underflow}

  def nip_catch(%{stack: [val, _catch_offset | rest]} = state),
    do: {:ok, %{state | stack: [val | rest]}}

  def nip_catch(_state), do: {:error, :stack_underflow}

  def post_update(state, fun) do
    with {:ok, expr, state} <- pop(state) do
      {pair, state} = bind(state, temp_name(state.temp), compiler_call(fun, [expr]))
      {:ok, %{state | stack: [tuple_element(pair, 1), tuple_element(pair, 2) | state.stack]}}
    end
  end

  def unary_call(state, mod, fun, extra_args \\ []) do
    with {:ok, expr, state} <- pop(state) do
      {:ok, push(state, remote_call(mod, fun, [expr | extra_args]))}
    end
  end

  def effectful_push(state, expr) do
    {bound, state} = bind(state, temp_name(state.temp), expr)
    {:ok, push(state, bound)}
  end

  def unary_local_call(state, fun) do
    with {:ok, expr, state} <- pop(state) do
      {:ok, push(state, local_call(fun, [expr]))}
    end
  end

  def binary_call(state, mod, fun) do
    with {:ok, right, state} <- pop(state),
         {:ok, left, state} <- pop(state) do
      {:ok, push(state, remote_call(mod, fun, [left, right]))}
    end
  end

  def binary_local_call(state, fun) do
    with {:ok, right, state} <- pop(state),
         {:ok, left, state} <- pop(state) do
      {:ok, push(state, local_call(fun, [left, right]))}
    end
  end

  def get_field2(state, atom_idx) do
    with {:ok, obj, state} <- pop(state) do
      field = remote_call(RuntimeHelpers, :get_field, [obj, literal(atom_idx)])
      {:ok, %{state | stack: [field, obj | state.stack]}}
    end
  end

  def put_field_call(state, atom_idx) do
    with {:ok, val, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      {:ok,
       %{state | body: state.body ++ [compiler_call(:put_field, [obj, literal(atom_idx), val])]}}
    end
  end

  def define_field_call(state, atom_idx) do
    with {:ok, val, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      {:ok, push(state, compiler_call(:define_field, [obj, literal(atom_idx), val]))}
    end
  end

  def put_array_el_call(state) do
    with {:ok, val, state} <- pop(state),
         {:ok, idx, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      {:ok, %{state | body: state.body ++ [compiler_call(:put_array_el, [obj, idx, val])]}}
    end
  end

  def invoke_call(state, argc) do
    with {:ok, args, state} <- pop_n(state, argc),
         {:ok, fun, state} <- pop(state) do
      effectful_push(state, compiler_call(:invoke_runtime, [fun, list_expr(Enum.reverse(args))]))
    end
  end

  def invoke_constructor_call(state, argc) do
    with {:ok, args, state} <- pop_n(state, argc),
         {:ok, new_target, state} <- pop(state),
         {:ok, ctor, state} <- pop(state) do
      effectful_push(
        state,
        compiler_call(:construct_runtime, [ctor, new_target, list_expr(Enum.reverse(args))])
      )
    end
  end

  def invoke_tail_call(state, argc) do
    with {:ok, args, state} <- pop_n(state, argc),
         {:ok, fun, %{stack: []} = state} <- pop(state) do
      {:done,
       state.body ++ [compiler_call(:invoke_runtime, [fun, list_expr(Enum.reverse(args))])]}
    else
      {:ok, _fun, _state} -> {:error, :stack_not_empty_on_tail_call}
      {:error, _} = error -> error
    end
  end

  def invoke_method_call(state, argc) do
    with {:ok, args, state} <- pop_n(state, argc),
         {:ok, fun, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      effectful_push(
        state,
        compiler_call(:invoke_method_runtime, [fun, obj, list_expr(Enum.reverse(args))])
      )
    end
  end

  def array_from_call(state, argc) do
    with {:ok, elems, state} <- pop_n(state, argc) do
      {:ok, push(state, compiler_call(:array_from, [list_expr(Enum.reverse(elems))]))}
    end
  end

  def in_call(state) do
    with {:ok, obj, state} <- pop(state),
         {:ok, key, state} <- pop(state) do
      {:ok,
       push(state, remote_call(QuickBEAM.BeamVM.Interpreter.Objects, :has_property, [obj, key]))}
    end
  end

  def append_call(state) do
    with {:ok, obj, state} <- pop(state),
         {:ok, idx, state} <- pop(state),
         {:ok, arr, state} <- pop(state) do
      {pair, state} =
        bind(state, temp_name(state.temp), compiler_call(:append_spread, [arr, idx, obj]))

      {:ok, %{state | stack: [tuple_element(pair, 1), tuple_element(pair, 2) | state.stack]}}
    end
  end

  def copy_data_properties_call(state, mask) do
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

  def delete_call(state) do
    with {:ok, key, state} <- pop(state),
         {:ok, obj, state} <- pop(state) do
      effectful_push(state, compiler_call(:delete_property, [obj, key]))
    end
  end

  def invoke_tail_method_call(state, argc) do
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

  def goto(state, target, stack_depths) do
    with {:ok, call} <- block_jump_call(state, target, stack_depths) do
      {:done, state.body ++ [call]}
    end
  end

  def branch(%{stack: stack}, idx, next_entry, target, sense, _stack_depths) when stack == [] do
    {:error, {:missing_branch_condition, idx, target, sense, next_entry}}
  end

  def branch(state, _idx, next_entry, target, sense, _stack_depths) when is_nil(next_entry) do
    {:error, {:missing_fallthrough_block, target, sense, state.body}}
  end

  def branch(state, _idx, next_entry, target, sense, stack_depths) do
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

  def return_top(state) do
    with {:ok, expr, _state} <- pop(state) do
      {:done, state.body ++ [expr]}
    end
  end

  def throw_top(state) do
    with {:ok, expr, _state} <- pop(state) do
      {:done, state.body ++ [throw_js(expr)]}
    end
  end

  def bind(state, name, expr) do
    var = var(name)
    {var, %{state | body: state.body ++ [match(var, expr)], temp: state.temp + 1}}
  end

  def block_jump_call(state, target, stack_depths) do
    block_jump_call_values(target, stack_depths, current_slots(state), current_stack(state))
  end

  def block_jump_call_values(target, stack_depths, slots, stack) do
    expected_depth = Map.get(stack_depths, target)
    actual_depth = length(stack)

    cond do
      is_nil(expected_depth) ->
        {:error, {:unknown_block_target, target}}

      expected_depth != actual_depth ->
        {:error, {:stack_depth_mismatch, target, expected_depth, actual_depth}}

      true ->
        {:ok, local_call(block_name(target), slots ++ stack)}
    end
  end

  def current_slots(state), do: ordered_slot_values(state.slots)
  def current_stack(state), do: state.stack

  def block_name(idx), do: String.to_atom("block_#{idx}")
  def slot_name(idx, n), do: "Slot#{idx}_#{n}"
  def temp_name(n), do: "Tmp#{n}"
  def slot_var(idx), do: var("Slot#{idx}")
  def stack_var(idx), do: var("Stack#{idx}")
  def slot_vars(0), do: []
  def slot_vars(count), do: Enum.map(0..(count - 1), &slot_var/1)
  def stack_vars(0), do: []
  def stack_vars(count), do: Enum.map(0..(count - 1), &stack_var/1)

  def var(name) when is_binary(name), do: {:var, @line, String.to_atom(name)}
  def var(name) when is_integer(name), do: {:var, @line, String.to_atom(Integer.to_string(name))}
  def var(name) when is_atom(name), do: {:var, @line, name}

  def integer(value), do: {:integer, @line, value}
  def atom(value), do: {:atom, @line, value}
  def literal(value), do: :erl_parse.abstract(value)
  def match(left, right), do: {:match, @line, left, right}

  def tuple_element(tuple, index) do
    {:call, @line, {:remote, @line, {:atom, @line, :erlang}, {:atom, @line, :element}},
     [integer(index), tuple]}
  end

  def list_expr([]), do: {nil, @line}
  def list_expr([head | tail]), do: {:cons, @line, head, list_expr(tail)}

  def remote_call(mod, fun, args) do
    {:call, @line, {:remote, @line, {:atom, @line, mod}, {:atom, @line, fun}}, args}
  end

  def local_call(fun, args), do: {:call, @line, {:atom, @line, fun}, args}
  def compiler_call(fun, args), do: remote_call(RuntimeHelpers, fun, args)

  def throw_js(expr), do: remote_call(:erlang, :throw, [{:tuple, @line, [atom(:js_throw), expr]}])

  def try_catch_expr(try_body, err_var, catch_body) do
    {:try, @line, try_body, [], [catch_clause(err_var, catch_body)], []}
  end

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

  defp catch_clause(err_var, catch_body) do
    pattern =
      {:tuple, @line, [atom(:throw), {:tuple, @line, [atom(:js_throw), err_var]}, var(:_)]}

    {:clause, @line, [pattern], [], catch_body}
  end
end
