defmodule QuickBEAM.VM.Runtime.ValueTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Runtime.Symbol
  alias QuickBEAM.VM.Runtime.Value

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
    assert Value.to_number("  ") == 0
    assert Value.to_number("Infinity") == :infinity
    assert Value.to_number("-Infinity") == :neg_infinity
    assert Value.to_number("0x10") == 16
    assert Value.to_number("0b10") == 2
    assert Value.to_number("0o10") == 8
    assert Value.to_string_value(-0.0) == "0"
    assert Value.to_string_value(1.0) == "1"
    assert Value.typeof(Symbol.iterator()) == "symbol"
    assert Value.strict_equal?(Symbol.iterator(), Symbol.iterator())
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
    assert Value.binary(:div, -1, 0) == :neg_infinity
    assert Value.binary(:div, 1, -0.0) == :neg_infinity
    assert Value.binary(:div, -1, -0.0) == :infinity
    assert Value.binary(:div, 0, 0) == :nan
    assert Value.binary(:div, :infinity, :infinity) == :nan
    assert Value.binary(:div, :neg_infinity, 2) == :neg_infinity
    assert Value.binary(:div, 2, :infinity) == 0.0
    assert Value.binary(:mod, 7, 4) == 3
    assert <<1::1, _magnitude::63>> = <<Value.binary(:mod, -4, 2)::float>>
    assert Value.binary(:mod, :infinity, 4) == :nan
    assert Value.binary(:mod, 4, :infinity) == 4
    assert Value.binary(:add, :infinity, :neg_infinity) == :nan
    assert Value.binary(:sub, :infinity, :infinity) == :nan
    assert Value.binary(:mul, :neg_infinity, -2) == :infinity
    assert Value.binary(:mul, :infinity, 0) == :nan
    assert Value.binary(:pow, 2, 3) == 8.0
    assert Value.binary(:pow, :infinity, -1) == 0.0
    assert Value.binary(:pow, -1, :infinity) == :nan
    assert Value.unary(:neg, :infinity) == :neg_infinity
    assert <<1::1, _magnitude::63>> = <<Value.unary(:neg, 0)::float>>
    assert Value.binary(:lt, "10", "2")
    assert Value.binary(:lt, :neg_infinity, -1)
    assert Value.binary(:lt, 1, :infinity)
    refute Value.binary(:gt, :neg_infinity, 1)
    assert Value.binary(:eq, "1", 1)
    refute Value.binary(:strict_eq, "1", 1)
  end

  test "executes extended-number arithmetic without leaking BEAM arithmetic errors" do
    source =
      "[Infinity + -Infinity, Infinity - Infinity, -Infinity * -2, Infinity * 0, Infinity / Infinity, 1 / -0, -4 % 2, Infinity ** -1, (-1) ** Infinity, -Infinity < -1, 1 < Infinity]"

    assert {:ok, program} = QuickBEAM.VM.compile(source)

    assert {:ok,
            [
              :nan,
              :nan,
              :infinity,
              :nan,
              :nan,
              :neg_infinity,
              negative_zero,
              +0.0,
              :nan,
              true,
              true
            ]} = QuickBEAM.VM.eval(program)

    assert <<1::1, _magnitude::63>> = <<negative_zero::float>>
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
