defmodule QuickBEAM.VM.Compiler.Lowering.Emit do
  @moduledoc "Operand-stack and body-emission helpers for compiler lowering state."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Types}

  @doc "Prepends one Erlang abstract-form expression to the accumulated body."
  def emit(state, expr), do: %{state | body: [expr | state.body]}

  def emit_all(state, exprs), do: %{state | body: Enum.reverse(exprs, state.body)}

  def bind(state, name, expr) do
    var = Builder.var(name)
    {var, %{state | body: [Builder.match(var, expr) | state.body], temp: state.temp + 1}}
  end

  @doc "Pushes an expression and optional type onto the lowering operand stack."
  def push(state, expr), do: push(state, expr, Types.infer_expr_type(expr))

  def push(state, expr, type),
    do: %{state | stack: [expr | state.stack], stack_types: [type | state.stack_types]}

  @doc "Pushes several expressions onto the lowering operand stack in stack order."
  def push_many(state, exprs, types) when length(exprs) == length(types),
    do: %{state | stack: exprs ++ state.stack, stack_types: types ++ state.stack_types}

  @doc "Binds a runtime call that returns a tuple and pushes selected tuple elements."
  def bind_pair(state, name, call, types) do
    {pair, state} = bind(state, name, call)
    elements = Enum.map(1..length(types), &Builder.tuple_element(pair, &1))
    push_many(state, elements, types)
  end

  def pop_typed(%{stack: [expr | rest], stack_types: [type | type_rest]} = state),
    do: {:ok, expr, type, %{state | stack: rest, stack_types: type_rest}}

  def pop_typed(_state), do: {:error, :stack_underflow}

  def pop(%{stack: [expr | rest], stack_types: [_type | type_rest]} = state),
    do: {:ok, expr, %{state | stack: rest, stack_types: type_rest}}

  def pop(_state), do: {:error, :stack_underflow}

  @doc "Pops several operand-stack expressions preserving evaluation order."
  def pop_n(state, 0), do: {:ok, [], state}

  def pop_n(state, count) when count > 0 do
    with {:ok, expr, state} <- pop(state),
         {:ok, rest, state} <- pop_n(state, count - 1) do
      {:ok, [expr | rest], state}
    end
  end

  @doc "Pops several operand-stack expressions with their inferred types."
  def pop_n_typed(state, 0), do: {:ok, [], [], state}

  def pop_n_typed(state, count) when count > 0 do
    with {:ok, expr, type, state} <- pop_typed(state),
         {:ok, rest, rest_types, state} <- pop_n_typed(state, count - 1) do
      {:ok, [expr | rest], [type | rest_types], state}
    end
  end

  @doc "Binds a stack entry to a temporary variable when it must be evaluated once."
  def bind_stack_entry(state, idx) do
    case Enum.fetch(state.stack, idx) do
      {:ok, expr} ->
        {bound, state} = bind(state, Builder.temp_name(state.temp), expr)
        {:ok, %{state | stack: List.replace_at(state.stack, idx, bound)}, bound}

      :error ->
        :error
    end
  end

  @doc "Binds every current stack entry so catch/finally continuations evaluate values once."
  def freeze_stack(%{stack: []} = state), do: {[], state}

  def freeze_stack(state) do
    state =
      Enum.reduce(0..(length(state.stack) - 1), state, fn idx, state ->
        {:ok, state, _bound} = bind_stack_entry(state, idx)
        state
      end)

    {state.stack, state}
  end

  @doc "Duplicates the top operand-stack expression."
  def duplicate_top(%{stack: [expr | rest], stack_types: [type | type_rest]} = state) do
    {bound, state} = bind(state, Builder.temp_name(state.temp), expr)
    {:ok, %{state | stack: [bound, bound | rest], stack_types: [type, type | type_rest]}}
  end

  def duplicate_top(_state), do: {:error, :stack_underflow}

  @doc "Duplicates the top two operand-stack expressions preserving order."
  def duplicate_top_two(%{stack: [a, b | rest], stack_types: [ta, tb | type_rest]} = state) do
    {bound_b, state} = bind(state, Builder.temp_name(state.temp), b)
    {bound_a, state} = bind(state, Builder.temp_name(state.temp), a)

    {:ok,
     %{
       state
       | stack: [bound_a, bound_b, bound_a, bound_b | rest],
         stack_types: [ta, tb, ta, tb | type_rest]
     }}
  end

  def duplicate_top_two(_state), do: {:error, :stack_underflow}

  @doc "Reorders the top two operand-stack expressions for DUP-style bytecode operations."
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

  @doc "Reorders the top three operand-stack expressions for DUP-style bytecode operations."
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

  @doc "Drops the top operand-stack expression."
  def drop_top(%{stack: [_ | rest], stack_types: [_ | type_rest]} = state),
    do: {:ok, %{state | stack: rest, stack_types: type_rest}}

  def drop_top(_state), do: {:error, :stack_underflow}

  @doc "Swaps the top two operand-stack expressions."
  def swap_top(%{stack: [a, b | rest], stack_types: [ta, tb | type_rest]} = state),
    do: {:ok, %{state | stack: [b, a | rest], stack_types: [tb, ta | type_rest]}}

  def swap_top(_state), do: {:error, :stack_underflow}

  @doc "Permutes the top three operand-stack expressions."
  def permute_top_three(
        %{stack: [a, b, c | rest], stack_types: [ta, tb, tc | type_rest]} = state
      ),
      do: {:ok, %{state | stack: [a, c, b | rest], stack_types: [ta, tc, tb | type_rest]}}

  def permute_top_three(_state), do: {:error, :stack_underflow}

  def nip_catch(
        %{
          stack: [val, _discard, _catch_offset, next_fn, iter_obj | rest],
          stack_types: [type, _discard_type, _catch_type, next_type, iter_type | type_rest]
        } = state
      ) do
    {:ok,
     %{
       state
       | stack: [val, next_fn, iter_obj | rest],
         stack_types: [type, next_type, iter_type | type_rest]
     }}
  end

  def nip_catch(
        %{stack: [val, _catch_offset | rest], stack_types: [type, _ | type_rest]} = state
      ),
      do: {:ok, %{state | stack: [val | rest], stack_types: [type | type_rest]}}

  def nip_catch(_state), do: {:error, :stack_underflow}
end
