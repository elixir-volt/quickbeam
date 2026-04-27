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

  test "recovers for-in declaration initializers without consuming in as binary operator" do
    assert {:error,
            %AST.Program{
              body: [
                %AST.ForInStatement{
                  left: %AST.VariableDeclaration{
                    declarations: [%AST.VariableDeclarator{init: %AST.Identifier{name: "first"}}]
                  }
                }
              ]
            }, errors} = Parser.parse("for (var key = first in object) ;")

    assert Enum.any?(errors, &(&1.message == "for-in/of declaration cannot have initializer"))
  end
end
