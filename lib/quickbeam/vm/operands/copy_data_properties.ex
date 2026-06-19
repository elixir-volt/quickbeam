defmodule QuickBEAM.VM.Operands.CopyDataProperties do
  @moduledoc "Decodes QuickJS copy_data_properties packed operand masks."

  import Bitwise, only: [&&&: 2, bsr: 2]

  @doc "Returns stack indexes encoded by a copy_data_properties mask."
  def decode(mask) when is_integer(mask) do
    %{
      target_idx: mask &&& 3,
      source_idx: bsr(mask, 2) &&& 7,
      exclude_idx: bsr(mask, 5) &&& 7
    }
  end
end
