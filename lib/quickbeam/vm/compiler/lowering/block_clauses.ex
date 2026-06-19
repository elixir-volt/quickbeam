defmodule QuickBEAM.VM.Compiler.Lowering.BlockClauses do
  @moduledoc "Builds block function arguments and guard clauses from inferred type state."

  alias QuickBEAM.VM.Compiler.Lowering.Builder

  @guardable_types [:integer, :number, :boolean, :string, :undefined, :null]

  @doc "Returns the Erlang forms used as block function arguments."
  def args(_slot_count, stack_depth, :tuple) do
    [Builder.ctx_var(), Builder.var("Slots"), Builder.var("Captures")] ++
      Builder.stack_vars(stack_depth)
  end

  def args(slot_count, stack_depth, _frame_mode) do
    [Builder.ctx_var() | Builder.slot_vars(slot_count)] ++
      Builder.stack_vars(stack_depth) ++ Builder.capture_vars(slot_count)
  end

  @doc "Returns fast-path guards for a block clause."
  def guards(_slot_count, _stack_depth, nil, _frame_mode), do: []

  def guards(_slot_count, stack_depth, entry_type_state, :tuple),
    do: stack_guards(stack_depth, entry_type_state)

  def guards(slot_count, stack_depth, entry_type_state, _frame_mode) do
    slot_guards =
      if slot_count == 0 do
        []
      else
        for idx <- 0..(slot_count - 1),
            guard =
              type_guard(
                Builder.slot_var(idx),
                Map.get(entry_type_state.slot_types, idx, :unknown)
              ),
            guard != nil,
            do: guard
      end

    slot_guards ++ stack_guards(stack_depth, entry_type_state)
  end

  defp stack_guards(stack_depth, entry_type_state) do
    for {type, idx} <- Enum.with_index(entry_type_state.stack_types || []),
        idx < stack_depth,
        guard = type_guard(Builder.stack_var(idx), type),
        guard != nil,
        do: guard
  end

  defp type_guard(_expr, type) when type not in @guardable_types, do: nil
  defp type_guard(expr, :integer), do: Builder.is_integer_guard(expr)
  defp type_guard(expr, :number), do: Builder.is_number_guard(expr)
  defp type_guard(expr, :boolean), do: Builder.is_boolean_guard(expr)
  defp type_guard(expr, :string), do: Builder.is_binary_guard(expr)
  defp type_guard(expr, :undefined), do: Builder.equal(expr, Builder.atom(:undefined))
  defp type_guard(expr, :null), do: Builder.equal(expr, Builder.atom(nil))
end
