defmodule QuickBEAM.JS.Parser.Literals.BasicsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "parses object and array literals" do
    assert {:ok, %AST.Program{body: [statement]}} =
             Parser.parse("value = { a: [1, 2], b, c() { return 3; } };")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{properties: [a, b, c]}
             }
           } = statement

    assert %AST.Property{
             key: %AST.Identifier{name: "a"},
             value: %AST.ArrayExpression{elements: [_, _]}
           } = a

    assert %AST.Property{key: %AST.Identifier{name: "b"}, shorthand: true} = b

    assert %AST.Property{
             key: %AST.Identifier{name: "c"},
             method: true,
             value: %AST.FunctionExpression{}
           } = c
  end
end
