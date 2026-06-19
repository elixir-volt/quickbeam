defmodule QuickBEAM.JS.Parser.Literals.RegexpUnicodeEscapeDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects invalid unicode regexp escapes" do
    for source <- [
          "/\\u{1,}/u;",
          "/\\u{110000}/u;",
          "/\\u{1F_639}/u;",
          "/\\M/u;",
          "/(?<a>\\a)/u;",
          "/\\c0/u;",
          "/{/u;"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid escape sequence in regular expression"))
    end
  end

  test "allows valid unicode regexp escapes" do
    for source <- ["/\\u{10FFFF}/u;", "/\\n/u;", "/\\./u;", "/\\cA/u;", "/a{2}/u;"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
