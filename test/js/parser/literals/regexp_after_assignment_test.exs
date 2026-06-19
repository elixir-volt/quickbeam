defmodule QuickBEAM.JS.Parser.Literals.RegexpAfterAssignmentTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible regexp literals after assignment operators" do
    source = """
    value = /assign/;
    value ||= /or/;
    value ??= /nullish/;
    """

    assert {:ok, %AST.Program{body: [assign, or_assign, nullish_assign]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               operator: "=",
               right: %AST.Literal{value: %{pattern: "assign"}}
             }
           } = assign

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               operator: "||=",
               right: %AST.Literal{value: %{pattern: "or"}}
             }
           } = or_assign

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               operator: "??=",
               right: %AST.Literal{value: %{pattern: "nullish"}}
             }
           } = nullish_assign
  end
end
