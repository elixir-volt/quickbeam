defmodule QuickBEAM.JS.Parser.Patterns.NestedDestructuringAssignmentTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible nested destructuring assignment syntax" do
    source = """
    ({ a: { b = 1 }, c: [first, ...tail] } = object);
    """

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               left: %AST.ObjectPattern{
                 properties: [
                   %AST.Property{
                     value: %AST.ObjectPattern{
                       properties: [
                         %AST.Property{value: %AST.AssignmentPattern{}}
                       ]
                     }
                   },
                   %AST.Property{
                     value: %AST.ArrayPattern{
                       elements: [%AST.Identifier{name: "first"}, %AST.RestElement{}]
                     }
                   }
                 ]
               },
               right: %AST.Identifier{name: "object"}
             }
           } = statement
  end
end
