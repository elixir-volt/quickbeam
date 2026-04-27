defmodule QuickBEAM.JS.Parser.Patterns.ObjectRestBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible object rest binding syntax" do
    source = """
    var { a, ...rest } = obj;
    function f({ a, ...rest }) {}
    """

    assert {:ok, %AST.Program{body: [declaration, function_decl]}} = Parser.parse(source)

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{
                 id: %AST.ObjectPattern{
                   properties: [_, %AST.RestElement{argument: %AST.Identifier{name: "rest"}}]
                 }
               }
             ]
           } = declaration

    assert %AST.FunctionDeclaration{
             params: [
               %AST.ObjectPattern{
                 properties: [_, %AST.RestElement{argument: %AST.Identifier{name: "rest"}}]
               }
             ]
           } = function_decl
  end
end
