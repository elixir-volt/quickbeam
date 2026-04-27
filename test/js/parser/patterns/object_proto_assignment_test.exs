defmodule QuickBEAM.JS.Parser.Patterns.ObjectProtoAssignmentTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "allows duplicate __proto__ names in object assignment patterns" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.AssignmentExpression{
                    right: %AST.AssignmentExpression{
                      left: %AST.ObjectPattern{
                        properties: [
                          %AST.Property{key: %AST.Identifier{name: "__proto__"}},
                          %AST.Property{key: %AST.Identifier{name: "__proto__"}}
                        ]
                      }
                    }
                  }
                }
              ]
            }} = Parser.parse("result = { __proto__: x, __proto__: y } = value;")
  end

  test "keeps duplicate __proto__ data properties invalid in object initializers" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse("object = { __proto__: first, \"__proto__\": second };")

    assert Enum.any?(errors, &(&1.message == "duplicate __proto__ property"))
  end
end
