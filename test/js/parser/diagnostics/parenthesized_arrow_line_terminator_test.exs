defmodule QuickBEAM.JS.Parser.Diagnostics.ParenthesizedArrowLineTerminatorTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects line terminator before parenthesized arrow" do
    assert {:error, %AST.Program{}, _errors} = Parser.parse("var af = ()\n=> {};")
  end

  test "preserves same-line parenthesized arrow" do
    assert {:ok, %AST.Program{}} = Parser.parse("var af = () => {};")
  end
end
