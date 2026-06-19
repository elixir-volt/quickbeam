defmodule QuickBEAM.JS.Parser.Expressions.AsyncNumericMethodKeyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible async numeric object method names" do
    source = "object = { async 0() { return 1; }, async *1.5() { yield 2; } };"

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{
                 properties: [
                   %AST.Property{
                     key: %AST.Literal{value: 0},
                     value: %AST.FunctionExpression{async: true, generator: false}
                   },
                   %AST.Property{
                     key: %AST.Literal{value: 1.5},
                     value: %AST.FunctionExpression{async: true, generator: true}
                   }
                 ]
               }
             }
           } = statement
  end
end
