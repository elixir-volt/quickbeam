defmodule QuickBEAM.JS.Parser.ControlFlow.ForDestructuringTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible for-in and for-of destructuring syntax" do
    source = """
    for (const [key, value] of entries) { continue; }
    for (let { name } in objects) { break; }
    """

    assert {:ok, %AST.Program{body: [for_of, for_in]}} = Parser.parse(source)

    assert %AST.ForOfStatement{
             left: %AST.VariableDeclaration{
               kind: :const,
               declarations: [
                 %AST.VariableDeclarator{
                   id: %AST.ArrayPattern{
                     elements: [%AST.Identifier{name: "key"}, %AST.Identifier{name: "value"}]
                   }
                 }
               ]
             },
             right: %AST.Identifier{name: "entries"},
             body: %AST.BlockStatement{body: [%AST.ContinueStatement{}]}
           } = for_of

    assert %AST.ForInStatement{
             left: %AST.VariableDeclaration{
               kind: :let,
               declarations: [
                 %AST.VariableDeclarator{
                   id: %AST.ObjectPattern{
                     properties: [%AST.Property{key: %AST.Identifier{name: "name"}}]
                   }
                 }
               ]
             },
             right: %AST.Identifier{name: "objects"},
             body: %AST.BlockStatement{body: [%AST.BreakStatement{}]}
           } = for_in
  end
end
