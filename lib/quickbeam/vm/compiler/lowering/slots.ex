defmodule QuickBEAM.VM.Compiler.Lowering.Slots do
  @moduledoc "Slot and capture-cell storage helpers for compiler lowering state."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Types}

  def put_slot(state, idx, expr), do: put_slot(state, idx, expr, Types.infer_expr_type(expr))

  def put_slot(state, idx, expr, type) do
    %{
      state
      | slots: Map.put(state.slots, idx, expr),
        slot_types: Map.put(state.slot_types, idx, type),
        slot_inits: Map.put(state.slot_inits, idx, true)
    }
  end

  def put_uninitialized_slot(state, idx, expr),
    do: put_uninitialized_slot(state, idx, expr, Types.infer_expr_type(expr))

  def put_uninitialized_slot(state, idx, expr, type) do
    %{
      state
      | slots: Map.put(state.slots, idx, expr),
        slot_types: Map.put(state.slot_types, idx, type),
        slot_inits: Map.put(state.slot_inits, idx, false)
    }
  end

  def slot_expr(state, idx), do: Map.get(state.slots, idx, Builder.atom(:undefined))
  def slot_type(state, idx), do: Map.get(state.slot_types, idx, :unknown)
  def slot_initialized?(state, idx), do: Map.get(state.slot_inits, idx, false)

  def put_capture_cell(state, idx, expr),
    do: %{state | capture_cells: Map.put(state.capture_cells, idx, expr)}

  def capture_cell_expr(state, idx),
    do: Map.get(state.capture_cells, idx, Builder.atom(:undefined))

  def current_slots(state), do: ordered_values(state.slots)
  def current_capture_cells(state), do: ordered_values(state.capture_cells)

  defp ordered_values(map) do
    map
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_, expr} -> expr end)
  end
end
