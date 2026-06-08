defmodule QuickBEAM.Chunk do
  @moduledoc """
  A validated JavaScript chunk.

  Chunks are produced by `QuickBEAM.compile_chunk/2` or the `~JS` sigil with the
  `c` modifier. They keep source text plus optional native bytecode so callers can
  pass a first-class script value to `QuickBEAM.eval/3`.
  """

  @type t :: %__MODULE__{source: String.t(), bytecode: binary() | nil, filename: String.t()}
  defstruct [:source, :bytecode, filename: ""]
end
