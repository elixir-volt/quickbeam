defmodule QuickBEAM.BeamVM.Compiler.Analysis.CFG do
  @moduledoc false

  alias QuickBEAM.BeamVM.Compiler.Analysis

  defdelegate block_entries(instructions), to: Analysis
  defdelegate next_entry(entries, start), to: Analysis
  defdelegate predecessor_counts(instructions, entries), to: Analysis
  defdelegate predecessor_sources(instructions, entries), to: Analysis
  defdelegate inlineable_entries(instructions, entries), to: Analysis
  defdelegate opcode_name(op), to: Analysis
  defdelegate matching_nip_catch(instructions, catch_idx), to: Analysis
  defdelegate block_terminal(instructions, start, next_entry), to: Analysis
  defdelegate block_successors(instructions, entries, start), to: Analysis
end
