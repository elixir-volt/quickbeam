defmodule QuickBEAM.JS.Parser.Expressions.ReservedPropertyNamesTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible reserved object property names" do
    source = "object = { default: 1, class: 2, import() { return 3; } };"

    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{expression: %AST.AssignmentExpression{right: object}}
              ]
            }} =
             Parser.parse(source)

    assert %AST.ObjectExpression{
             properties: [
               %AST.Property{
                 key: %AST.Identifier{name: "default"},
                 value: %AST.Literal{value: 1}
               },
               %AST.Property{key: %AST.Identifier{name: "class"}, value: %AST.Literal{value: 2}},
               %AST.Property{
                 key: %AST.Identifier{name: "import"},
                 method: true,
                 value: %AST.FunctionExpression{}
               }
             ]
           } = object
  end
end
