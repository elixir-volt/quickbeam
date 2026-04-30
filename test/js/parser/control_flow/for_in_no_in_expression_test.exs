defmodule QuickBEAM.JS.Parser.ControlFlow.ForInNoInExpressionTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS private member for-in left-hand side" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ClassDeclaration{
                  body: [
                    %AST.FieldDefinition{},
                    %AST.MethodDefinition{
                      value: %AST.FunctionExpression{
                        body: %AST.BlockStatement{
                          body: [
                            %AST.ForInStatement{
                              left: %AST.MemberExpression{
                                property: %AST.PrivateIdentifier{name: "field"}
                              }
                            }
                          ]
                        }
                      }
                    }
                  ]
                }
              ]
            }} = Parser.parse("class C { #field; m() { for (this.#field in {a: 0}) ; } }")
  end

  test "ports Annex B var for-in declaration initializers" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ForInStatement{
                  left: %AST.VariableDeclaration{
                    kind: :var,
                    declarations: [%AST.VariableDeclarator{init: %AST.Identifier{name: "first"}}]
                  }
                }
              ]
            }} = Parser.parse("for (var key = first in object) ;")
  end
end
