defmodule QuickBEAM.JS.Parser.ControlFlow.ForConstInOfTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible const for-in and for-of declarations" do
    source = """
    for (const key in object) { use(key); }
    for (const value of iterable) { use(value); }
    """

    assert {:ok, %AST.Program{body: [for_in, for_of]}} = Parser.parse(source)

    assert %AST.ForInStatement{
             left: %AST.VariableDeclaration{
               kind: :const,
               declarations: [%AST.VariableDeclarator{id: %AST.Identifier{name: "key"}}]
             },
             right: %AST.Identifier{name: "object"}
           } = for_in

    assert %AST.ForOfStatement{
             left: %AST.VariableDeclaration{
               kind: :const,
               declarations: [%AST.VariableDeclarator{id: %AST.Identifier{name: "value"}}]
             },
             right: %AST.Identifier{name: "iterable"}
           } = for_of
  end
end
