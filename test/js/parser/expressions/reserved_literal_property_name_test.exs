defmodule QuickBEAM.JS.Parser.Expressions.ReservedLiteralPropertyNameTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS boolean and null object property names" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{
                  declarations: [
                    %AST.VariableDeclarator{
                      init: %AST.ObjectExpression{
                        properties: [
                          %AST.Property{key: %AST.Identifier{name: "null"}},
                          %AST.Property{key: %AST.Identifier{name: "true"}},
                          %AST.Property{key: %AST.Identifier{name: "false"}}
                        ]
                      }
                    }
                  ]
                }
              ]
            }} = Parser.parse("var tokenCodes = { null: 1, true: 2, false: 3 };")
  end

  test "ports QuickJS boolean and null accessor property names" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{
                  declarations: [
                    %AST.VariableDeclarator{
                      init: %AST.ObjectExpression{
                        properties: [
                          %AST.Property{kind: :set, key: %AST.Identifier{name: "null"}},
                          %AST.Property{kind: :get, key: %AST.Identifier{name: "true"}}
                        ]
                      }
                    }
                  ]
                }
              ]
            }} = Parser.parse("var tokenCodes = { set null(value) {}, get true() {} };")
  end
end
