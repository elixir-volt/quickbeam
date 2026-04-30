defmodule QuickBEAM.JS.Parser.Literals.RegexpClassRangeDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects unicode class ranges involving character classes" do
    for source <- ["/[\\d-a]/u;", "/[%-\\d]/u;", "/[\\s-\\d]/u;", "/[--\\d]/u;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid class range"))
    end
  end

  test "allows simple unicode class ranges" do
    assert {:ok, %AST.Program{}} = Parser.parse("/[a-z]/u;")
  end
end
