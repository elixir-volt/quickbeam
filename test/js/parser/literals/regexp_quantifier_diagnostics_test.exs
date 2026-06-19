defmodule QuickBEAM.JS.Parser.Literals.RegexpQuantifierDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects quantifiers without atoms" do
    for source <- ["/?/;", "/{2}/;", "/{2,3}/;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "nothing to repeat"))
    end
  end

  test "rejects quantified lookbehinds and unicode-mode lookaheads" do
    for source <- ["/.(?<=.)?/;", "/.(?<!.+){2,3}/;", "/(?=.)?/u", "/(?!.){2}/u"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "nothing to repeat"))
    end
  end

  test "allows Annex B quantified lookaheads without unicode mode" do
    assert {:ok, %AST.Program{}} = Parser.parse("/(?=.)?/;")
  end
end
