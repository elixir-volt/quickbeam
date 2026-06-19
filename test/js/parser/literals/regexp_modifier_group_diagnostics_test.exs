defmodule QuickBEAM.JS.Parser.Literals.RegexpModifierGroupDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects invalid regexp modifier groups" do
    for source <- [
          "/(?y:a)/;",
          "/(?ii:a)/;",
          "/(?s-s:a)/;",
          "/(?-:a)/;",
          "/(?ms-i)/;",
          "/(?\\u006d:a)/;"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid group"))
    end
  end

  test "allows valid regexp modifier and assertion groups" do
    for source <- ["/(?i:a)/;", "/(?im-s:a)/;", "/(?:a)/;", "/(?=a)/;", "/(?<name>a)/;"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
