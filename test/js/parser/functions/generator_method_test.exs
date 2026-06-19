defmodule QuickBEAM.JS.Parser.Functions.GeneratorMethodTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible generator method syntax" do
    source = """
    value = { *m() { yield x; } };
    class C { *m() { yield x; } static *[name]() {} }
    """

    assert {:ok, %AST.Program{body: [object_statement, class_statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{
                 properties: [
                   %AST.Property{value: %AST.FunctionExpression{generator: true}, method: true}
                 ]
               }
             }
           } = object_statement

    assert %AST.ClassDeclaration{
             body: [
               %AST.MethodDefinition{
                 value: %AST.FunctionExpression{generator: true},
                 computed: false
               },
               %AST.MethodDefinition{
                 value: %AST.FunctionExpression{generator: true},
                 computed: true,
                 static: true
               }
             ]
           } = class_statement
  end
end
