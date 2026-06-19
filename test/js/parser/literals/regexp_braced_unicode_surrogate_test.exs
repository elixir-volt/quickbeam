defmodule QuickBEAM.JS.Parser.Literals.RegexpBracedUnicodeSurrogateTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows braced unicode escapes with surrogate code points in unicode regexps" do
    for source <- ["/\\u{D83D}/u;", "/\\u{DC38}/u;", "/\\u{D83D}\\u{DC38}+/u;"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
