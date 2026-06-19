defmodule QuickBEAM.VM.LEB128Test do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.LEB128

  test "read_signed sign-extends negative single-byte values" do
    assert {:ok, -1, <<>>} = LEB128.read_signed(<<0x7F>>)
    assert {:ok, -2, <<>>} = LEB128.read_signed(<<0x7E>>)
  end

  test "read_signed keeps positive values positive" do
    assert {:ok, 0, <<>>} = LEB128.read_signed(<<0x00>>)
    assert {:ok, 63, <<>>} = LEB128.read_signed(<<0x3F>>)
  end
end
