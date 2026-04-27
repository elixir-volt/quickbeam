defmodule QuickBEAM.JS.Parser.Functions.AsyncGeneratorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible async generator function syntax" do
    source = """
    async function *g() { yield await value; }
    value = async function *h() { yield 1; };
    """

    assert {:ok, %AST.Program{body: [declaration, expression]}} = Parser.parse(source)

    assert %AST.FunctionDeclaration{id: %AST.Identifier{name: "g"}, async: true, generator: true} =
             declaration

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.FunctionExpression{
                 id: %AST.Identifier{name: "h"},
                 async: true,
                 generator: true
               }
             }
           } = expression
  end
end
