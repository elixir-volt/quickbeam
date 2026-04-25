defmodule QuickBEAM.VM.Compiler.Lowering.State.Stack do
  @moduledoc "Virtual operand stack: push/pop, typed variants, multi-element manipulations."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Types}

  def push(state, expr), do: push(state, expr, Types.infer_expr_type(expr))

  def push(state, expr, type),
    do: %{state | stack: [expr | state.stack], stack_types: [type | state.stack_types]}

  def pop_typed(%{stack: [expr | rest], stack_types: [type | type_rest]} = state),
    do: {:ok, expr, type, %{state | stack: rest, stack_types: type_rest}}

  def pop_typed(_state), do: {:error, :stack_underflow}

  def pop(%{stack: [expr | rest], stack_types: [_type | type_rest]} = state),
    do: {:ok, expr, %{state | stack: rest, stack_types: type_rest}}

  def pop(_state), do: {:error, :stack_underflow}

  def pop_n(state, 0), do: {:ok, [], state}

  def pop_n(state, count) when count > 0 do
    with {:ok, expr, state} <- pop(state),
         {:ok, rest, state} <- pop_n(state, count - 1) do
      {:ok, [expr | rest], state}
    end
  end

  def pop_n_typed(state, 0), do: {:ok, [], [], state}

  def pop_n_typed(state, count) when count > 0 do
    with {:ok, expr, type, state} <- pop_typed(state),
         {:ok, rest, rest_types, state} <- pop_n_typed(state, count - 1) do
      {:ok, [expr | rest], [type | rest_types], state}
    end
  end

  def bind_stack_entry(state, idx) do
    case Enum.fetch(state.stack, idx) do
      {:ok, expr} ->
        {bound, state} = bind(state, Builder.temp_name(state.temp), expr)
        {:ok, %{state | stack: List.replace_at(state.stack, idx, bound)}, bound}

      :error ->
        :error
    end
  end

  def duplicate_top(state) do
    with {:ok, expr, type, state} <- pop_typed(state) do
      {bound, state} = bind(state, Builder.temp_name(state.temp), expr)

      {:ok,
       %{
         state
         | stack: [bound, bound | state.stack],
           stack_types: [type, type | state.stack_types]
       }}
    end
  end

  def duplicate_top_two(state) do
    with {:ok, first, first_type, state} <- pop_typed(state),
         {:ok, second, second_type, state} <- pop_typed(state) do
      {second_bound, state} = bind(state, Builder.temp_name(state.temp), second)
      {first_bound, state} = bind(state, Builder.temp_name(state.temp), first)

      {:ok,
       %{
         state
         | stack: [first_bound, second_bound, first_bound, second_bound | state.stack],
           stack_types: [first_type, second_type, first_type, second_type | state.stack_types]
       }}
    end
  end

  def insert_top_two(state) do
    with {:ok, first, first_type, state} <- pop_typed(state),
         {:ok, second, second_type, state} <- pop_typed(state) do
      {first_bound, state} = bind(state, Builder.temp_name(state.temp), first)

      {:ok,
       %{
         state
         | stack: [first_bound, second, first_bound | state.stack],
           stack_types: [first_type, second_type, first_type | state.stack_types]
       }}
    end
  end

  def insert_top_three(state) do
    with {:ok, first, first_type, state} <- pop_typed(state),
         {:ok, second, second_type, state} <- pop_typed(state),
         {:ok, third, third_type, state} <- pop_typed(state) do
      {first_bound, state} = bind(state, Builder.temp_name(state.temp), first)

      {:ok,
       %{
         state
         | stack: [first_bound, second, third, first_bound | state.stack],
           stack_types: [first_type, second_type, third_type, first_type | state.stack_types]
       }}
    end
  end

  def drop_top(%{stack: [_ | rest], stack_types: [_ | type_rest]} = state),
    do: {:ok, %{state | stack: rest, stack_types: type_rest}}

  def drop_top(_state), do: {:error, :stack_underflow}

  def swap_top(%{stack: [a, b | rest], stack_types: [ta, tb | type_rest]} = state),
    do: {:ok, %{state | stack: [b, a | rest], stack_types: [tb, ta | type_rest]}}

  def swap_top(_state), do: {:error, :stack_underflow}

  def permute_top_three(
        %{stack: [a, b, c | rest], stack_types: [ta, tb, tc | type_rest]} = state
      ),
      do: {:ok, %{state | stack: [a, c, b | rest], stack_types: [ta, tc, tb | type_rest]}}

  def permute_top_three(_state), do: {:error, :stack_underflow}

  defp bind(state, name, expr) do
    var = Builder.var(name)
    {var, %{state | body: [Builder.match(var, expr) | state.body], temp: state.temp + 1}}
  end
end
