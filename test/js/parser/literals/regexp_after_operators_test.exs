defmodule QuickBEAM.JS.Parser.Literals.RegexpAfterOperatorsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible regexp literals after expression operators" do
    source = """
    value = condition ? /yes/ : /no/;
    other = left || /fallback/;
    more = left && /right/;
    """

    assert {:ok, %AST.Program{body: [conditional, logical_or, logical_and]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ConditionalExpression{
                 consequent: %AST.Literal{value: %{pattern: "yes"}},
                 alternate: %AST.Literal{value: %{pattern: "no"}}
               }
             }
           } = conditional

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.LogicalExpression{
                 operator: "||",
                 right: %AST.Literal{value: %{pattern: "fallback"}}
               }
             }
           } = logical_or

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.LogicalExpression{
                 operator: "&&",
                 right: %AST.Literal{value: %{pattern: "right"}}
               }
             }
           } = logical_and
  end
end
