defmodule QuickBEAM.VM.Compiler.Lowering.Effects do
  @moduledoc "Effect handling helpers for compiler lowering state."

  alias QuickBEAM.VM.Compiler.SemanticEffects, as: CompilerEffects
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit, Types}

  def effectful_push(state, expr),
    do: effectful_push(state, expr, Types.infer_expr_type(expr))

  def effectful_push(state, expr, type) do
    {bound, state} = Emit.bind(state, Builder.temp_name(state.temp), expr)
    {:ok, Emit.push(state, bound, type)}
  end

  def apply_effect(state, operation, obj \\ nil) do
    if CompilerEffects.invalidates_shape_aliases?(operation) do
      invalidate_shaped_aliases(state, obj)
    else
      state
    end
  end

  def invalidate_shaped_aliases(state, _obj \\ nil) do
    slot_types =
      Map.new(state.slot_types, fn {idx, type} ->
        if shaped_object_type?(type), do: {idx, :object}, else: {idx, type}
      end)

    %{state | slot_types: slot_types}
  end

  defp shaped_object_type?({:shaped_object, _offsets}), do: true
  defp shaped_object_type?({:shaped_object, _offsets, _values}), do: true
  defp shaped_object_type?(_type), do: false
end
