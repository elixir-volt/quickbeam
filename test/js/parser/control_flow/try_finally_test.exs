defmodule QuickBEAM.JS.Parser.ControlFlow.TryFinallyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible try-finally syntax without catch" do
    source = """
    try { work(); } finally { cleanup(); }
    """

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.TryStatement{
             block: %AST.BlockStatement{
               body: [
                 %AST.ExpressionStatement{
                   expression: %AST.CallExpression{callee: %AST.Identifier{name: "work"}}
                 }
               ]
             },
             handler: nil,
             finalizer: %AST.BlockStatement{
               body: [
                 %AST.ExpressionStatement{
                   expression: %AST.CallExpression{callee: %AST.Identifier{name: "cleanup"}}
                 }
               ]
             }
           } = statement
  end
end
