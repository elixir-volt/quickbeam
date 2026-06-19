defmodule QuickBEAM.JS.Parser.Expressions.VoidExpressionTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS void expression syntax" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("value = void 0;")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.UnaryExpression{operator: "void", argument: %AST.Literal{value: 0}}
             }
           } = statement
  end
end
