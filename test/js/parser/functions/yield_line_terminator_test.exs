defmodule QuickBEAM.JS.Parser.Functions.YieldLineTerminatorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible yield ASI line terminator syntax" do
    source = """
    function *f() {
      yield
      value;
    }
    """

    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{
                  generator: true,
                  body: %AST.BlockStatement{body: [yield_statement, expression_statement]}
                }
              ]
            }} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.YieldExpression{argument: nil, delegate: false}
           } = yield_statement

    assert %AST.ExpressionStatement{expression: %AST.Identifier{name: "value"}} =
             expression_statement
  end
end
