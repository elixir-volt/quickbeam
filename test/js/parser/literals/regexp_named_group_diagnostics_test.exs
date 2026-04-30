defmodule QuickBEAM.JS.Parser.Literals.RegexpNamedGroupDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects invalid regexp named capture group names" do
    for source <- ["/(?<>a)/;", "/(?<1>a)/;", "/(?<a-b>a)/;", "/(?<a>a)(?<a>b)/;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message in ["invalid group name", "duplicate group name"]))
    end
  end

  test "rejects dangling named backreferences in unicode mode" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("/\\k<missing>/u;")
    assert Enum.any?(errors, &(&1.message == "group name not defined"))
  end

  test "allows Annex B identity escape fallback for named backreference syntax" do
    assert {:ok, %AST.Program{}} = Parser.parse("/\\k<missing>/;")
  end

  test "allows valid named captures and backreferences" do
    assert {:ok, %AST.Program{}} = Parser.parse("/(?<name>a)\\k<name>/u;")
  end
end
