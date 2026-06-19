defmodule QuickBEAM.JS.Parser.Functions.AwaitCallMemberTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS await call and member syntax" do
    source = """
    async function f() {
      await obj.method(arg);
      await obj.value;
    }
    """

    assert {:ok, %AST.Program{body: [%AST.FunctionDeclaration{async: true, body: body}]}} =
             Parser.parse(source)

    assert %AST.BlockStatement{body: [await_call, await_member]} = body

    assert %AST.ExpressionStatement{
             expression: %AST.AwaitExpression{
               argument: %AST.CallExpression{
                 callee: %AST.MemberExpression{property: %AST.Identifier{name: "method"}}
               }
             }
           } = await_call

    assert %AST.ExpressionStatement{
             expression: %AST.AwaitExpression{
               argument: %AST.MemberExpression{property: %AST.Identifier{name: "value"}}
             }
           } = await_member
  end
end
