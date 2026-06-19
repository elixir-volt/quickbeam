defmodule QuickBEAM.JS.Parser.Functions.SpreadTrailingArgumentTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible spread argument trailing comma syntax" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("f(...args,);")

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.Identifier{name: "f"},
               arguments: [%AST.SpreadElement{argument: %AST.Identifier{name: "args"}}]
             }
           } = statement
  end
end
