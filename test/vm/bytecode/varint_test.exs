defmodule QuickBEAM.VM.Bytecode.VarintTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Bytecode.Varint, as: VMVarint

  test "delegates unsigned decoding to Varint.LEB128 and preserves the remainder" do
    encoded = Varint.LEB128.encode(300)
    assert {:ok, 300, <<1, 2>>} = VMVarint.read_unsigned(encoded <> <<1, 2>>)
  end

  test "decodes QuickJS ZigZag signed values through Varint.LEB128" do
    encoded = Varint.LEB128.encode(1_248_969)
    assert {:ok, -624_485, <<3>>} = VMVarint.read_signed(encoded <> <<3>>)
  end

  test "reads QuickJS fixed-width little-endian fields separately from varints" do
    assert {:ok, 0x12345678, <<9>>} =
             VMVarint.read_fixed_u32(<<0x12345678::little-unsigned-32, 9>>)
  end

  test "rejects unterminated and wider-than-32-bit encodings" do
    assert {:error, :bad_leb128} =
             VMVarint.read_unsigned(<<0x80, 0x80, 0x80, 0x80, 0x80, 0>>)

    assert {:error, :integer_overflow} =
             VMVarint.read_unsigned(Varint.LEB128.encode(0x1_0000_0000))

    assert {:error, :integer_overflow} =
             VMVarint.read_signed(Varint.LEB128.encode(0x1_0000_0000))
  end
end
