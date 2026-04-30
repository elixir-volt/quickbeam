defmodule QuickBEAM.JS.Parser.ControlFlow.ForOfHeadExpressionTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects async as a for-of left-hand side" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("var async; for (async of [1]) ;")
    assert errors != []
  end

  test "rejects comma expressions in for-of right-hand side" do
    for source <- ["for (x of [], []) {}", "for (var x of [], []) {}", "for (let x of [], []) {}"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert errors != []
    end
  end
end
