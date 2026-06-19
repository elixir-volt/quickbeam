defmodule QuickBEAM.JS.Parser.Patterns.NestedDestructuringBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible nested destructuring binding syntax" do
    source = """
    const { a: { b = 1 }, c: [first, ...tail] } = object;
    """

    assert {:ok, %AST.Program{body: [declaration]}} = Parser.parse(source)

    assert %AST.VariableDeclaration{
             kind: :const,
             declarations: [
               %AST.VariableDeclarator{
                 id: %AST.ObjectPattern{
                   properties: [
                     %AST.Property{
                       value: %AST.ObjectPattern{
                         properties: [%AST.Property{value: %AST.AssignmentPattern{}}]
                       }
                     },
                     %AST.Property{
                       value: %AST.ArrayPattern{
                         elements: [%AST.Identifier{name: "first"}, %AST.RestElement{}]
                       }
                     }
                   ]
                 },
                 init: %AST.Identifier{name: "object"}
               }
             ]
           } = declaration
  end
end
