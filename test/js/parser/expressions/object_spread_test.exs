defmodule QuickBEAM.JS.Parser.Expressions.ObjectSpreadTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible object spread property syntax" do
    source = "object = { a: 1, ...rest, b };"

    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{expression: %AST.AssignmentExpression{right: object}}
              ]
            }} =
             Parser.parse(source)

    assert %AST.ObjectExpression{
             properties: [
               %AST.Property{key: %AST.Identifier{name: "a"}, value: %AST.Literal{value: 1}},
               %AST.SpreadElement{argument: %AST.Identifier{name: "rest"}},
               %AST.Property{
                 key: %AST.Identifier{name: "b"},
                 value: %AST.Identifier{name: "b"},
                 shorthand: true
               }
             ]
           } = object
  end
end
