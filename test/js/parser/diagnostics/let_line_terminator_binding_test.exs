defmodule QuickBEAM.JS.Parser.Diagnostics.LetLineTerminatorBindingTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "keeps let followed by let or yield across a line terminator as lexical declarations" do
    for source <- ["let\nlet = 1;", "function *f() { let\nyield 0; }"] do
      assert {:error, %AST.Program{}, [_ | _]} = Parser.parse(source)
    end
  end
end
