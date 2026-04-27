defmodule QuickBEAM.JS.Parser.Expressions.DeleteMemberTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS delete computed and super member syntax" do
    source = """
    delete "abc"[100];
    a = { f() { delete super.a; } };
    """

    assert {:ok, %AST.Program{body: [delete_string_index, object_method]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.UnaryExpression{
               operator: "delete",
               argument: %AST.MemberExpression{object: %AST.Literal{value: "abc"}, computed: true}
             }
           } = delete_string_index

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{
                 properties: [
                   %AST.Property{
                     method: true,
                     value: %AST.FunctionExpression{
                       body: %AST.BlockStatement{
                         body: [
                           %AST.ExpressionStatement{
                             expression: %AST.UnaryExpression{
                               operator: "delete",
                               argument: %AST.MemberExpression{
                                 object: %AST.Identifier{name: "super"}
                               }
                             }
                           }
                         ]
                       }
                     }
                   }
                 ]
               }
             }
           } = object_method
  end
end
