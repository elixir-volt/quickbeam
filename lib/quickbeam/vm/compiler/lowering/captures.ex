defmodule QuickBEAM.VM.Compiler.Lowering.Captures do
  @moduledoc "Capture-cell management during lowering: ensures and closes shared cells for captured local variables."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, State}

  @doc "Ensures a capture cell exists for a local slot."
  def ensure_capture_cell(state, idx) do
    {bound, state} =
      State.bind(
        state,
        Builder.capture_name(idx, state.temp),
        State.compiler_call(state, :ensure_capture_cell, [
          State.capture_cell_expr(state, idx),
          State.slot_expr(state, idx)
        ])
      )

    {:ok, State.put_capture_cell(state, idx, bound), bound}
  end

  @doc "Closes a capture cell over the current slot value."
  def close_capture_cell(state, idx) do
    {bound, state} =
      State.bind(
        state,
        Builder.capture_name(idx, state.temp),
        State.compiler_call(state, :close_capture_cell, [
          State.capture_cell_expr(state, idx),
          State.slot_expr(state, idx)
        ])
      )

    {:ok, State.put_capture_cell(state, idx, bound)}
  end

  @doc "Synchronizes a capture cell with the current slot value."
  def sync_capture_cell(state, idx, expr) do
    if slot_captured?(state, idx) do
      %{
        state
        | body: [
            State.compiler_call(state, :sync_capture_cell, [
              State.capture_cell_expr(state, idx),
              expr
            ])
            | state.body
          ]
      }
    else
      state
    end
  end

  @doc "Returns whether a local slot is captured by a closure."
  def slot_captured?(%{locals: locals}, idx) when is_list(locals) do
    case Enum.at(locals, idx) do
      %{is_captured: true} -> true
      _ -> false
    end
  end

  def slot_captured?(_state, _idx), do: false
end
