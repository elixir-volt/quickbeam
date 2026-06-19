defmodule QuickBEAM.JS.Parser.Literals.UnicodeWhitespaceAfterRegexpTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "treats ECMAScript unicode spaces as trivia after regexp literals" do
    for whitespace <- [
          "\u00A0",
          "\u1680",
          "\u2000",
          "\u2001",
          "\u2002",
          "\u2003",
          "\u2004",
          "\u2005",
          "\u2006",
          "\u2007",
          "\u2008",
          "\u2009",
          "\u200A",
          "\u202F",
          "\u205F",
          "\u3000",
          "\uFEFF"
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse("/a/" <> whitespace <> ";")
    end
  end
end
