defmodule QuickBEAM.JS.Parser.Literals.RegexpNamedGroupEdgeDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects non-identifier regexp group names" do
    for source <- ["/(?<❤>a)/;", "/(?<𐒤>a)/;", "/(?<$❞>a)/;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid group name"))
    end
  end

  test "rejects incomplete named backreferences" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("/(?<a>.)\\k/;")
    assert Enum.any?(errors, &(&1.message == "expecting group name"))
  end
end
