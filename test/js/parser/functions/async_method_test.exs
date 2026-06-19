defmodule QuickBEAM.JS.Parser.Functions.AsyncMethodTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible async object and class method syntax" do
    source = """
    value = { async m() { await x; }, async [name]() { return 1; } };
    class C { async m() { await x; } static async [name]() {} }
    """

    assert {:ok, %AST.Program{body: [object_statement, class_statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{
                 properties: [
                   %AST.Property{
                     value: %AST.FunctionExpression{async: true},
                     method: true,
                     computed: false
                   },
                   %AST.Property{
                     value: %AST.FunctionExpression{async: true},
                     method: true,
                     computed: true
                   }
                 ]
               }
             }
           } = object_statement

    assert %AST.ClassDeclaration{
             body: [
               %AST.MethodDefinition{
                 value: %AST.FunctionExpression{async: true},
                 computed: false
               },
               %AST.MethodDefinition{
                 value: %AST.FunctionExpression{async: true},
                 computed: true,
                 static: true
               }
             ]
           } = class_statement
  end
end
