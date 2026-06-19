defmodule QuickBEAM.JS.Parser.ControlFlow.ForNestedDestructuringTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible for-of nested destructuring syntax" do
    source = """
    for (const { a: [first, ...rest] } of entries) { use(first); }
    """

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ForOfStatement{
             left: %AST.VariableDeclaration{
               kind: :const,
               declarations: [
                 %AST.VariableDeclarator{
                   id: %AST.ObjectPattern{
                     properties: [
                       %AST.Property{
                         value: %AST.ArrayPattern{
                           elements: [%AST.Identifier{name: "first"}, %AST.RestElement{}]
                         }
                       }
                     ]
                   }
                 }
               ]
             },
             right: %AST.Identifier{name: "entries"}
           } = statement
  end
end
