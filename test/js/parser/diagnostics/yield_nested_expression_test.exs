defmodule QuickBEAM.JS.Parser.Diagnostics.YieldNestedExpressionTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects nested yield expressions in binary yield operands" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse("var g = function*() { yield 3 + yield 4; };")

    assert Enum.any?(errors, &(&1.message == "yield expression not allowed here"))
  end

  test "allows yield as the direct operand of another yield" do
    assert {:ok, %AST.Program{}} = Parser.parse("var g = function*() { yield yield 1; };")
  end

  test "allows nested yield when parenthesized inside a yield operand" do
    assert {:ok, %AST.Program{}} = Parser.parse("var g = function*() { yield 3 + (yield 4); };")
  end
end
