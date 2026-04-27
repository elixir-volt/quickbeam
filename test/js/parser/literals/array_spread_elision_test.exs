defmodule QuickBEAM.JS.Parser.Literals.ArraySpreadElisionTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS array spread elision syntax" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("x = [ ...[ , ] ];")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ArrayExpression{
                 elements: [%AST.SpreadElement{argument: %AST.ArrayExpression{elements: [nil]}}]
               }
             }
           } = statement
  end
end
