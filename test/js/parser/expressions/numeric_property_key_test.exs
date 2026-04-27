defmodule QuickBEAM.JS.Parser.Expressions.NumericPropertyKeyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible numeric object property names" do
    source = "object = { 0: zero, 1.5: decimal, 0x10: hex };"

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{
                 properties: [
                   %AST.Property{key: %AST.Literal{value: 0}},
                   %AST.Property{key: %AST.Literal{value: 1.5}},
                   %AST.Property{key: %AST.Literal{value: 16}}
                 ]
               }
             }
           } = statement
  end
end
