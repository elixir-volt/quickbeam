defmodule QuickBEAM.JS.Parser.Expressions.SequenceTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS comma sequence expression syntax used in template tests" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("value = (a, b, c);")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.SequenceExpression{
                 expressions: [
                   %AST.Identifier{name: "a"},
                   %AST.Identifier{name: "b"},
                   %AST.Identifier{name: "c"}
                 ]
               }
             }
           } = statement
  end
end
