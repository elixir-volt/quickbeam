defmodule QuickBEAM.JS.Parser.Patterns.DestructuringTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS basic array destructuring declaration" do
    source = """
    function * g () { return 0; };
    var [x] = g();
    """

    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{generator: true},
                %AST.EmptyStatement{},
                declaration
              ]
            }} =
             Parser.parse(source)

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{
                 id: %AST.ArrayPattern{elements: [%AST.Identifier{name: "x"}]},
                 init: %AST.CallExpression{callee: %AST.Identifier{name: "g"}}
               }
             ]
           } = declaration
  end

  test "ports QuickJS array binding defaults and rest syntax" do
    assert {:ok, %AST.Program{body: [declaration]}} =
             Parser.parse("var [a, b = 1, ...rest] = value;")

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{
                 id: %AST.ArrayPattern{
                   elements: [
                     %AST.Identifier{name: "a"},
                     %AST.AssignmentPattern{left: %AST.Identifier{name: "b"}},
                     %AST.RestElement{argument: %AST.Identifier{name: "rest"}}
                   ]
                 }
               }
             ]
           } = declaration
  end
end
