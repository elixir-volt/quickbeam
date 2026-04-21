defmodule QuickBEAM.BeamVM.Compiler.Lowering.Captures do
  @moduledoc false

  alias QuickBEAM.BeamVM.Compiler.Lowering.State

  defdelegate ensure_capture_cell(state, idx), to: State
  defdelegate close_capture_cell(state, idx), to: State
end
