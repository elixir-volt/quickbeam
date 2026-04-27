defmodule QuickBEAM.JS.Parser.Functions.AsyncArrowTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible async arrow syntax" do
    source = """
    f = async x => await x;
    g = async (a, b = 1) => { return await a; };
    """

    assert {:ok, %AST.Program{body: [f, g]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ArrowFunctionExpression{
                 async: true,
                 params: [%AST.Identifier{name: "x"}],
                 body: %AST.AwaitExpression{}
               }
             }
           } = f

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ArrowFunctionExpression{
                 async: true,
                 params: [_, %AST.AssignmentPattern{}],
                 body: %AST.BlockStatement{}
               }
             }
           } = g
  end
end
