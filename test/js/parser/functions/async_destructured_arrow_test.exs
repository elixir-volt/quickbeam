defmodule QuickBEAM.JS.Parser.Functions.AsyncDestructuredArrowTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible async destructured arrow parameters" do
    source = "handler = async ({ value = await fallback() }, ...rest) => value;"

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ArrowFunctionExpression{
                 async: true,
                 params: [
                   %AST.ObjectPattern{
                     properties: [%AST.Property{value: %AST.AssignmentPattern{}}]
                   },
                   %AST.RestElement{argument: %AST.Identifier{name: "rest"}}
                 ],
                 body: %AST.Identifier{name: "value"}
               }
             }
           } = statement
  end
end
