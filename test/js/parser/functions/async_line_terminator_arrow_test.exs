defmodule QuickBEAM.JS.Parser.Functions.AsyncLineTerminatorArrowTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible async line terminator before arrow syntax" do
    source = "async\nx => x;"

    assert {:ok, %AST.Program{body: [async_statement, arrow_statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{expression: %AST.Identifier{name: "async"}} = async_statement

    assert %AST.ExpressionStatement{
             expression: %AST.ArrowFunctionExpression{
               async: false,
               params: [%AST.Identifier{name: "x"}]
             }
           } = arrow_statement
  end
end
