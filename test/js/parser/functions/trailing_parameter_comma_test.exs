defmodule QuickBEAM.JS.Parser.Functions.TrailingParameterCommaTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible trailing parameter comma syntax" do
    source = """
    function f(a, b,) { return a; }
    value = (a, b,) => a;
    """

    assert {:ok, %AST.Program{body: [function_decl, arrow_statement]}} = Parser.parse(source)

    assert %AST.FunctionDeclaration{
             params: [%AST.Identifier{name: "a"}, %AST.Identifier{name: "b"}]
           } = function_decl

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ArrowFunctionExpression{
                 params: [%AST.Identifier{name: "a"}, %AST.Identifier{name: "b"}]
               }
             }
           } = arrow_statement
  end
end
