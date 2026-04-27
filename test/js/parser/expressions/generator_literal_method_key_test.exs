defmodule QuickBEAM.JS.Parser.Expressions.GeneratorLiteralMethodKeyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible generator literal object method names" do
    source = ~s|object = { *"string-name"() { yield 1; }, *0() { yield 2; } };|

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{
                 properties: [
                   %AST.Property{
                     key: %AST.Literal{value: "string-name"},
                     value: %AST.FunctionExpression{generator: true}
                   },
                   %AST.Property{
                     key: %AST.Literal{value: 0},
                     value: %AST.FunctionExpression{generator: true}
                   }
                 ]
               }
             }
           } = statement
  end
end
