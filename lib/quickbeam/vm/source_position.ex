defmodule QuickBEAM.VM.SourcePosition do
  @moduledoc "Resolves VM instruction positions to source line and column metadata."

  @doc "Resolves a VM function instruction index to source line and column information."
  def source_position(%QuickBEAM.VM.Function{source_positions: positions}, insn_index)
      when is_tuple(positions) and is_integer(insn_index) and insn_index >= 0 and
             insn_index < tuple_size(positions),
      do: elem(positions, insn_index)

  def source_position(%QuickBEAM.VM.Function{} = fun, _insn_index),
    do: {fun.line_num, fun.col_num}
end
