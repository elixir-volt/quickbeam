defmodule QuickBEAM.JS.Parser.Literals.RegexpDecimalEscapeDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects unicode-mode decimal escapes without matching captures" do
    for source <- ["/\\1/u;", "/\\8/u;", "/(.)\\2/u;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "back reference out of range in regular expression")
             )
    end
  end

  test "allows unicode-mode decimal backreferences with matching captures" do
    assert {:ok, %AST.Program{}} = Parser.parse("/(.)\\1/u;")
  end
end
