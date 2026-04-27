defmodule QuickBEAM.JS.Parser.Expressions.ConditionalObjectPropertyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "does not consume object property separator after conditional value" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.AssignmentExpression{
                    right: %AST.ObjectExpression{
                      properties: [
                        %AST.Property{
                          key: %AST.MemberExpression{},
                          computed: true,
                          value: %AST.ConditionalExpression{}
                        }
                      ]
                    }
                  }
                }
              ]
            }} =
             Parser.parse(
               "ta.constructor = { [Symbol.species]: TA === Uint8Array ? Int32Array : Uint8Array, };"
             )
  end
end
