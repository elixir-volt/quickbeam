defmodule QuickBEAM.JS.Parser.Expressions.StringMethodKeyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible string object method names" do
    source = ~s|object = { "method-name"() { return 1; }, async "async-name"() { return 2; } };|

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{
                 properties: [
                   %AST.Property{key: %AST.Literal{value: "method-name"}, method: true},
                   %AST.Property{
                     key: %AST.Literal{value: "async-name"},
                     method: true,
                     value: %AST.FunctionExpression{async: true}
                   }
                 ]
               }
             }
           } = statement
  end
end
