defmodule QuickBEAM.JS.Parser.Expressions.NumberMemberCallTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS parenthesized number member call syntax" do
    assert {:ok, %AST.Program{body: [statement]}} =
             Parser.parse("(19686109595169230000).toString();")

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.MemberExpression{
                 object: %AST.Literal{value: value},
                 property: %AST.Identifier{name: "toString"}
               },
               arguments: []
             }
           } = statement

    assert value == 19_686_109_595_169_230_000
  end
end
