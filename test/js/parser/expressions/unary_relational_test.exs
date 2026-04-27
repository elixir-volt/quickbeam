defmodule QuickBEAM.JS.Parser.Expressions.UnaryRelationalTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS unary and relational expression syntax" do
    source = """
    r = ~1;
    r = !1;
    r = (1 < 2);
    r = (2 > 1);
    r = ('b' > 'a');
    """

    assert {:ok,
            %AST.Program{body: [bit_not, logical_not, less_than, greater_than, string_compare]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{right: %AST.UnaryExpression{operator: "~"}}
           } = bit_not

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{right: %AST.UnaryExpression{operator: "!"}}
           } = logical_not

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{right: %AST.BinaryExpression{operator: "<"}}
           } = less_than

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{right: %AST.BinaryExpression{operator: ">"}}
           } = greater_than

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.BinaryExpression{
                 operator: ">",
                 left: %AST.Literal{value: "b"},
                 right: %AST.Literal{value: "a"}
               }
             }
           } = string_compare
  end
end
