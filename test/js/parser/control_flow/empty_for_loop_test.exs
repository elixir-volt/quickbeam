defmodule QuickBEAM.JS.Parser.ControlFlow.EmptyForLoopTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible empty for loop clauses" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("for (;;) { break; }")

    assert %AST.ForStatement{
             init: nil,
             test: nil,
             update: nil,
             body: %AST.BlockStatement{body: [%AST.BreakStatement{}]}
           } = statement
  end
end
