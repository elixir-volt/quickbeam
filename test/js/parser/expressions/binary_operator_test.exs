defmodule QuickBEAM.JS.Parser.Expressions.BinaryOperatorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS binary and logical operator syntax" do
    source = """
    r = 1 + 2 * 3 ** 4;
    a.x++;
    a[0]--;
    r = "x" in a && a instanceof Object;
    """

    assert {:ok, %AST.Program{body: [assignment, member_inc, element_dec, logical]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.BinaryExpression{
                 operator: "+",
                 right: %AST.BinaryExpression{
                   operator: "*",
                   right: %AST.BinaryExpression{operator: "**"}
                 }
               }
             }
           } = assignment

    assert %AST.ExpressionStatement{
             expression: %AST.UpdateExpression{
               operator: "++",
               prefix: false,
               argument: %AST.MemberExpression{computed: false}
             }
           } = member_inc

    assert %AST.ExpressionStatement{
             expression: %AST.UpdateExpression{
               operator: "--",
               prefix: false,
               argument: %AST.MemberExpression{computed: true}
             }
           } = element_dec

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.LogicalExpression{
                 operator: "&&",
                 left: %AST.BinaryExpression{operator: "in"},
                 right: %AST.BinaryExpression{operator: "instanceof"}
               }
             }
           } = logical
  end
end
