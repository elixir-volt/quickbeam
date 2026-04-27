defmodule QuickBEAM.JS.Parser.Literals.ObjectSpreadTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible object spread literal syntax" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("value = { a: 1, ...rest, b };")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{
                 properties: [
                   %AST.Property{key: %AST.Identifier{name: "a"}},
                   %AST.SpreadElement{argument: %AST.Identifier{name: "rest"}},
                   %AST.Property{key: %AST.Identifier{name: "b"}, shorthand: true}
                 ]
               }
             }
           } = statement
  end
end
