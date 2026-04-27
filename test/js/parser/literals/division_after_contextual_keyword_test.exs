defmodule QuickBEAM.JS.Parser.Literals.DivisionAfterContextualKeywordTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "tokenizes slash after contextual keyword identifiers as division" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{
                  declarations: [
                    %AST.VariableDeclarator{
                      init: %AST.BinaryExpression{
                        operator: "/",
                        left: %AST.BinaryExpression{
                          operator: "/",
                          left: %AST.Identifier{name: "instance"},
                          right: %AST.Identifier{name: "of"}
                        },
                        right: %AST.Identifier{name: "g"}
                      }
                    }
                  ]
                }
              ]
            }} = Parser.parse("var notRegExp = instance/of/g;")
  end
end
