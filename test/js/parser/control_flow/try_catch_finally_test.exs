defmodule QuickBEAM.JS.Parser.ControlFlow.TryCatchFinallyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible try-catch-finally syntax" do
    source = """
    try { work(); } catch (error) { handle(error); } finally { cleanup(); }
    """

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.TryStatement{
             block: %AST.BlockStatement{},
             handler: %AST.CatchClause{
               param: %AST.Identifier{name: "error"},
               body: %AST.BlockStatement{body: [%AST.ExpressionStatement{}]}
             },
             finalizer: %AST.BlockStatement{body: [%AST.ExpressionStatement{}]}
           } = statement
  end
end
