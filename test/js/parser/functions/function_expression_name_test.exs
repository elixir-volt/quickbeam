defmodule QuickBEAM.JS.Parser.Functions.FunctionExpressionNameTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS function expression name and IIFE syntax" do
    source = """
    f = function myfunc() { return myfunc; };
    (function() { return 1; })();
    (() => { return 1; })();
    """

    assert {:ok, %AST.Program{body: [assignment, function_iife, arrow_iife]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.FunctionExpression{id: %AST.Identifier{name: "myfunc"}}
             }
           } = assignment

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{callee: %AST.FunctionExpression{}}
           } =
             function_iife

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{callee: %AST.ArrowFunctionExpression{}}
           } =
             arrow_iife
  end
end
