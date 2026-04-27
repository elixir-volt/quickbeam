defmodule QuickBEAM.JS.Parser.Expressions.AccessorLiteralKeyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible object accessor literal keys" do
    source =
      ~s|object = { get "value-name"() { return 1; }, set 0(value) { this.value = value; } };|

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{
                 properties: [
                   %AST.Property{key: %AST.Literal{value: "value-name"}, kind: :get},
                   %AST.Property{key: %AST.Literal{value: 0}, kind: :set}
                 ]
               }
             }
           } = statement
  end
end
