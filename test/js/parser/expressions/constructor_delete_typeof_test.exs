defmodule QuickBEAM.JS.Parser.Expressions.ConstructorDeleteTypeofTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS constructor, delete, and typeof syntax" do
    source = """
    a = new Object;
    b = new F(2);
    delete a.x;
    r = typeof unknown_var;
    """

    assert {:ok,
            %AST.Program{body: [new_without_args, new_with_args, delete_member, typeof_expr]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.NewExpression{callee: %AST.Identifier{name: "Object"}, arguments: []}
             }
           } = new_without_args

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.NewExpression{
                 callee: %AST.Identifier{name: "F"},
                 arguments: [%AST.Literal{value: 2}]
               }
             }
           } = new_with_args

    assert %AST.ExpressionStatement{
             expression: %AST.UnaryExpression{
               operator: "delete",
               argument: %AST.MemberExpression{property: %AST.Identifier{name: "x"}}
             }
           } = delete_member

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.UnaryExpression{
                 operator: "typeof",
                 argument: %AST.Identifier{name: "unknown_var"}
               }
             }
           } = typeof_expr
  end
end
