defmodule QuickBEAM.JS.Parser.Functions.DestructuredParametersTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible destructured parameter syntax" do
    source = """
    function f({ a, b = 1, ...rest }, [first, ...tail]) { return a; }
    ({ a: value = 1 }) => value;
    """

    assert {:ok, %AST.Program{body: [function_decl, arrow_statement]}} = Parser.parse(source)

    assert %AST.FunctionDeclaration{
             params: [
               %AST.ObjectPattern{
                 properties: [
                   %AST.Property{},
                   %AST.Property{value: %AST.AssignmentPattern{}},
                   %AST.RestElement{}
                 ]
               },
               %AST.ArrayPattern{elements: [%AST.Identifier{name: "first"}, %AST.RestElement{}]}
             ]
           } = function_decl

    assert %AST.ExpressionStatement{
             expression: %AST.ArrowFunctionExpression{
               params: [
                 %AST.ObjectPattern{properties: [%AST.Property{value: %AST.AssignmentPattern{}}]}
               ]
             }
           } = arrow_statement
  end
end
