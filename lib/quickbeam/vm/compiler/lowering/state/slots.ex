defmodule QuickBEAM.VM.Compiler.Lowering.State.Slots do
  @moduledoc "Slot and capture-cell management: assignment, update, inline expressions, and ordered lists."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Captures, Types}

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

  def assign_slot(state, idx, keep?, wrapper \\ nil) do
    with {:ok, expr, type, state} <- pop_typed(state) do
      expr =
        if wrapper,
          do: compiler_call(state, wrapper, [expr]),
          else: expr

      {slot_expr, state} =
        if keep? or not Types.pure_expr?(expr) or Captures.slot_captured?(state, idx) do
          bind(state, Builder.slot_name(idx, state.temp), expr)
        else
          {expr, state}
        end

      state = put_slot(state, idx, slot_expr, type)
      state = Captures.sync_capture_cell(state, idx, slot_expr)
      state = if keep?, do: push(state, slot_expr, type), else: state
      {:ok, state}
    end
  end

  def update_slot(state, idx, expr),
    do: update_slot(state, idx, expr, false, Types.infer_expr_type(expr))

  def update_slot(state, idx, expr, keep?),
    do: update_slot(state, idx, expr, keep?, Types.infer_expr_type(expr))

  def update_slot(state, idx, expr, keep?, type) do
    {slot_expr, state} =
      if keep? or not Types.pure_expr?(expr) or Captures.slot_captured?(state, idx) do
        bind(state, Builder.slot_name(idx, state.temp), expr)
      else
        {expr, state}
      end

    state = put_slot(state, idx, slot_expr, type)
    state = Captures.sync_capture_cell(state, idx, slot_expr)
    state = if keep?, do: push(state, slot_expr, type), else: state
    {:ok, state}
  end

  def current_slots(state), do: ordered_values(state.slots)
  def current_capture_cells(state), do: ordered_values(state.capture_cells)

  defp ordered_values(values) do
    values
    |> Enum.sort_by(fn {idx, _expr} -> idx end)
    |> Enum.map(fn {_idx, expr} -> expr end)
  end

  defp bind(state, name, expr) do
    var = Builder.var(name)
    {var, %{state | body: [Builder.match(var, expr) | state.body], temp: state.temp + 1}}
  end

  defp push(state, expr, type),
    do: %{state | stack: [expr | state.stack], stack_types: [type | state.stack_types]}

  defp pop_typed(%{stack: [expr | rest], stack_types: [type | type_rest]} = state),
    do: {:ok, expr, type, %{state | stack: rest, stack_types: type_rest}}

  defp pop_typed(_state), do: {:error, :stack_underflow}

  defp compiler_call(%{ctx: ctx}, fun, args) do
    alias QuickBEAM.VM.Compiler.RuntimeHelpers
    Builder.remote_call(RuntimeHelpers, fun, [ctx | args])
  end
end
