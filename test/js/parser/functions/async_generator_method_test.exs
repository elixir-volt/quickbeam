defmodule QuickBEAM.JS.Parser.Functions.AsyncGeneratorMethodTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible async generator method syntax" do
    source = """
    value = { async *m() { yield await x; } };
    class C { async *m() { yield await x; } }
    """

    assert {:ok, %AST.Program{body: [object_statement, class_statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{
                 properties: [
                   %AST.Property{
                     value: %AST.FunctionExpression{async: true, generator: true},
                     method: true
                   }
                 ]
               }
             }
           } = object_statement

    assert %AST.ClassDeclaration{
             body: [
               %AST.MethodDefinition{value: %AST.FunctionExpression{async: true, generator: true}}
             ]
           } = class_statement
  end
end
