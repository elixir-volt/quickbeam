defmodule QuickBEAM.JS.Parser.Functions.RestSpreadCallTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible rest parameter and spread call syntax" do
    source = """
    function f(...args) { return args; }
    f(1, ...args);
    ((...args) => args)(...[1, 2]);
    """

    assert {:ok, %AST.Program{body: [function_decl, call_statement, arrow_call]}} =
             Parser.parse(source)

    assert %AST.FunctionDeclaration{
             params: [%AST.RestElement{argument: %AST.Identifier{name: "args"}}]
           } = function_decl

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               arguments: [
                 %AST.Literal{value: 1},
                 %AST.SpreadElement{argument: %AST.Identifier{name: "args"}}
               ]
             }
           } = call_statement

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.ArrowFunctionExpression{params: [%AST.RestElement{}]},
               arguments: [%AST.SpreadElement{argument: %AST.ArrayExpression{}}]
             }
           } = arrow_call
  end
end
