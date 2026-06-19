defmodule QuickBEAM.JS.Parser.Diagnostics.LetLineTerminatorAwaitTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "keeps let followed by await across a line terminator as a lexical declaration in async functions" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("async function f() { let\nawait 0; }")
    assert errors != []
  end
end
