defmodule QuickBEAM.JS.Parser.Functions.ArgumentScopeTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS argument-scope default and arrow parameter syntax" do
    source = """
    f = function(a, b = () => arguments) { return b; };
    f = function(a = eval("1"), b = () => arguments) { return b; };
    f = (a = eval("var c = 1"), probe = () => c) => { var c = 2; };
    f = function f(a = eval("var c = 1"), b = c, probe = () => c) { return probe; };
    f = function f(a = eval("var c = 1"), probe = (d = eval("c")) => d) { return probe; };
    """

    assert {:ok, %AST.Program{body: statements}} = Parser.parse(source)
    assert length(statements) == 5

    assert Enum.all?(statements, fn
             %AST.ExpressionStatement{
               expression: %AST.AssignmentExpression{right: %AST.FunctionExpression{}}
             } ->
               true

             %AST.ExpressionStatement{
               expression: %AST.AssignmentExpression{right: %AST.ArrowFunctionExpression{}}
             } ->
               true

             _ ->
               false
           end)
  end
end
