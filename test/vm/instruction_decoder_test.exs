defmodule QuickBEAM.VM.InstructionDecoderTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.InstructionDecoder

  test "decode rejects branch labels that do not land on an instruction" do
    assert {:error, {:invalid_label, 1}} = InstructionDecoder.decode(<<106, 0::little-signed-32>>)
  end
end
