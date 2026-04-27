defmodule QuickBEAM.JS.Parser.Expressions.ProtoMethodNonDuplicateTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible __proto__ method and computed property syntax" do
    source =
      ~S|object = { __proto__: base, __proto__() { return value; }, ["__proto__"]: override };|

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
                 key: %AST.Identifier{name: "__proto__"},
                 method: false,
                 computed: false
               },
               %AST.Property{
                 key: %AST.Identifier{name: "__proto__"},
                 method: true,
                 computed: false
               },
               %AST.Property{key: %AST.Literal{value: "__proto__"}, method: false, computed: true}
             ]
           } = object
  end
end
