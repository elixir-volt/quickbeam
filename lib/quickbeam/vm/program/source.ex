defmodule QuickBEAM.VM.Program.Source do
  @moduledoc "Resolves VM instruction positions to source line and column metadata."

  @type position :: {pos_integer(), pos_integer()}

  @doc "Resolves a VM function instruction index to source line and column information."
  @spec source_position(QuickBEAM.VM.Program.Function.t(), non_neg_integer()) :: position()
  def source_position(%QuickBEAM.VM.Program.Function{source_positions: positions}, insn_index)
      when is_tuple(positions) and is_integer(insn_index) and insn_index >= 0 and
             insn_index < tuple_size(positions),
      do: elem(positions, insn_index)

  def source_position(%QuickBEAM.VM.Program.Function{} = fun, _insn_index),
    do: {fun.line_num, fun.col_num}
end
