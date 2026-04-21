defmodule QuickBEAM.BeamVM.Compiler.Analysis.Stack do
  @moduledoc false

  alias QuickBEAM.BeamVM.Compiler.Analysis

  defdelegate infer_block_stack_depths(instructions, entries), to: Analysis
end
