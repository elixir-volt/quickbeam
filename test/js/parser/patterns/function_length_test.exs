defmodule QuickBEAM.JS.Parser.Patterns.FunctionLengthTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS arrow parameter default and destructuring syntax" do
    source = """
    var f = (a, b = 1, c) => {};
    var g = ([a,b]) => {};
    var h = ({a,b}) => {};
    var i = (c, [a,b] = 1, d) => {};
    """

    assert {:ok, %AST.Program{body: [f, g, h, i]}} = Parser.parse(source)

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{
                 init: %AST.ArrowFunctionExpression{params: [_, %AST.AssignmentPattern{}, _]}
               }
             ]
           } = f

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{
                 init: %AST.ArrowFunctionExpression{params: [%AST.ArrayPattern{}]}
               }
             ]
           } = g

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{
                 init: %AST.ArrowFunctionExpression{params: [%AST.ObjectPattern{}]}
               }
             ]
           } = h

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{
                 init: %AST.ArrowFunctionExpression{
                   params: [_, %AST.AssignmentPattern{left: %AST.ArrayPattern{}}, _]
                 }
               }
             ]
           } = i
  end
end
