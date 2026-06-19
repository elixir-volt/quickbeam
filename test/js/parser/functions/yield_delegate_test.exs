defmodule QuickBEAM.JS.Parser.Functions.YieldDelegateTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS generator delegated yield syntax" do
    source = """
    function *g(iterable) {
      yield *iterable;
      yield;
    }
    """

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.FunctionDeclaration{
             generator: true,
             params: [%AST.Identifier{name: "iterable"}],
             body: %AST.BlockStatement{
               body: [
                 %AST.ExpressionStatement{
                   expression: %AST.YieldExpression{
                     delegate: true,
                     argument: %AST.Identifier{name: "iterable"}
                   }
                 },
                 %AST.ExpressionStatement{
                   expression: %AST.YieldExpression{delegate: false, argument: nil}
                 }
               ]
             }
           } = statement
  end
end
