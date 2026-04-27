defmodule QuickBEAM.JS.Parser.Expressions.ObjectNamesCallChainTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS object names call-chain syntax" do
    assert {:ok, %AST.Program{body: [statement]}} =
             Parser.parse("Object.getOwnPropertyNames(x).toString();")

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.MemberExpression{
                 property: %AST.Identifier{name: "toString"},
                 object: %AST.CallExpression{
                   callee: %AST.MemberExpression{
                     object: %AST.Identifier{name: "Object"},
                     property: %AST.Identifier{name: "getOwnPropertyNames"}
                   },
                   arguments: [%AST.Identifier{name: "x"}]
                 }
               },
               arguments: []
             }
           } = statement
  end
end
