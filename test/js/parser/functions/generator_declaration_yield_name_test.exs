defmodule QuickBEAM.JS.Parser.Functions.GeneratorDeclarationYieldNameTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows yield as generator declaration name outside strict mode" do
    assert {:ok, %AST.Program{}} = Parser.parse("function* yield() { yield 1; }")
  end
end
