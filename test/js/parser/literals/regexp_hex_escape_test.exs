defmodule QuickBEAM.JS.Parser.Literals.RegexpHexEscapeTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows hex character escapes in unicode regexp literals" do
    for source <- ["/\\xDF/u;", "/(\\x6B)+/iu;"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
