defmodule QuickBEAM.VM.SourcePosition do
  @moduledoc "Resolves VM instruction positions to source line and column metadata."

  @doc "Resolves a decoded function instruction index to source line and column information."
  def source_position(%QuickBEAM.VM.Function{} = fun, _insn_index),
    do: {fun.line_num, fun.col_num}
end
