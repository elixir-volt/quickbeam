defmodule QuickBEAM.BeamVM.Compiler.Analysis.Types do
  @moduledoc false

  alias QuickBEAM.BeamVM.Compiler.Analysis

  defdelegate infer_block_entry_types(fun, instructions, entries, stack_depths), to: Analysis
  defdelegate function_type(fun), to: Analysis
end
