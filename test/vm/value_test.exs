defmodule QuickBEAM.VM.ValueTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Value

  test "centralizes JavaScript truthiness and primitive equality" do
    for value <- [nil, :undefined, :nan, false, 0, 0.0, ""] do
      refute Value.truthy?(value)
    end

    for value <- [true, 1, -1, "0", [], %{}] do
      assert Value.truthy?(value)
    end

    assert Value.strict_equal?(1, 1.0)
    refute Value.strict_equal?(:nan, :nan)
    assert Value.abstract_equal?(nil, :undefined)
    assert Value.abstract_equal?(true, 1)
    assert Value.abstract_equal?(42, "42")
    refute Value.abstract_equal?(0, nil)
  end

  test "dispatches canonical unary and binary arithmetic operations" do
    assert Value.unary(:plus, "12") == 12
    assert Value.unary(:neg, "2") == -2
    assert Value.unary(:lnot, 0)
    assert Value.unary(:inc, 2) == 3

    assert Value.binary(:add, "value=", 3) == "value=3"
    assert Value.binary(:sub, "7", 2) == 5
    assert Value.binary(:mul, 3, 4) == 12
    assert Value.binary(:div, 1, 0) == :infinity
    assert Value.binary(:div, 0, 0) == :nan
    assert Value.binary(:mod, 7, 4) == 3
    assert Value.binary(:pow, 2, 3) == 8.0
    assert Value.binary(:lt, "10", "2")
    assert Value.binary(:eq, "1", 1)
    refute Value.binary(:strict_eq, "1", 1)
  end

  test "uses signed Int32 coercion for bitwise opcode families" do
    assert Value.binary(:and, 7, 3) == 3
    assert Value.binary(:or, 4, 1) == 5
    assert Value.binary(:xor, 7, 3) == 4
    assert Value.binary(:shl, 1, 33) == 2
    assert Value.binary(:sar, -4, 1) == -2
    assert Value.binary(:shr, -1, 1) == 0x7FFFFFFF
    assert Value.unary(:not, 0) == -1
    assert Value.to_int32(0xFFFFFFFF) == -1
  end

  test "routes JavaScript string operations through UTF-16 code units" do
    high_surrogate = <<0xED, 0xA0, 0xBD>>

    assert Value.string_length("😀") == 2
    assert Value.string_at("😀", 0) == high_surrogate
    assert Value.string_char_code_at("😀", 0) == 0xD83D
    assert Value.string_slice("😀", 0, 1) == high_surrogate
    assert Value.string_from_units([0xD83D]) == high_surrogate
    assert Value.string_from_char_codes([0x1D83D]) == high_surrogate
  end
end
