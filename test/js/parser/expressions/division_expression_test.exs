defmodule QuickBEAM.JS.Parser.Expressions.DivisionExpressionTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible division expression tokenization" do
    source = """
    value = a / b / c;
    member = object.value / 2;
    call = fn() / divisor;
    """

    assert {:ok, %AST.Program{body: [division, member_division, call_division]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.BinaryExpression{
                 operator: "/",
                 left: %AST.BinaryExpression{operator: "/"}
               }
             }
           } = division

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.BinaryExpression{operator: "/", left: %AST.MemberExpression{}}
             }
           } = member_division

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.BinaryExpression{operator: "/", left: %AST.CallExpression{}}
             }
           } = call_division
  end
end
