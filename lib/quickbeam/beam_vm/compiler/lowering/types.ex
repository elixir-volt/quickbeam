defmodule QuickBEAM.BeamVM.Compiler.Lowering.Types do
  @moduledoc false

  alias QuickBEAM.BeamVM.Compiler.Lowering.State

  defdelegate infer_expr_type(expr), to: State
  defdelegate pure_expr?(expr), to: State
end
