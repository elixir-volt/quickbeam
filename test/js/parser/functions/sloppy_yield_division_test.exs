defmodule QuickBEAM.JS.Parser.Functions.SloppyYieldDivisionTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "tokenizes sloppy yield followed by slash as division when no regexp terminator exists" do
    assert {:ok, %AST.Program{}} =
             Parser.parse("var yield = 12, a = 3; yield /a; yieldParsedAsIdentifier = true;")
  end

  test "still tokenizes generator yield followed by a regexp literal" do
    assert {:ok, %AST.Program{}} = Parser.parse("function* g() { received = yield/abc/i; }")
  end
end
