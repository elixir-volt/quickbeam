defmodule QuickBEAM.JS.Parser.Modules.TopLevelAwaitTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible top-level await module syntax" do
    source = """
    await import("dep");
    value = await promise;
    """

    assert {:ok, %AST.Program{source_type: :module, body: [import_await, assignment]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExpressionStatement{
             expression: %AST.AwaitExpression{
               argument: %AST.CallExpression{callee: %AST.Identifier{name: "import"}}
             }
           } = import_await

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.AwaitExpression{argument: %AST.Identifier{name: "promise"}}
             }
           } = assignment
  end
end
