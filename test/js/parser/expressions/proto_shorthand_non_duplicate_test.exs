defmodule QuickBEAM.JS.Parser.Expressions.ProtoShorthandNonDuplicateTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible __proto__ shorthand with data property syntax" do
    source = "object = { __proto__, __proto__: base };"

    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{expression: %AST.AssignmentExpression{right: object}}
              ]
            }} =
             Parser.parse(source)

    assert %AST.ObjectExpression{
             properties: [
               %AST.Property{key: %AST.Identifier{name: "__proto__"}, shorthand: true},
               %AST.Property{key: %AST.Identifier{name: "__proto__"}, shorthand: false}
             ]
           } = object
  end
end
