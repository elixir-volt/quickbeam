defmodule QuickBEAM.JS.Parser.Functions.YieldIdentifierContextTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "allows yield as a sloppy binding and arrow parameter" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{
                  declarations: [%AST.VariableDeclarator{id: %AST.Identifier{name: "yield"}}]
                },
                %AST.VariableDeclaration{
                  declarations: [
                    %AST.VariableDeclarator{
                      init: %AST.ArrowFunctionExpression{
                        params: [%AST.Identifier{name: "yield"}]
                      }
                    }
                  ]
                }
              ]
            }} = Parser.parse("var yield; var af = yield => 1;")
  end

  test "parses yield expressions inside generator function bodies" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{
                  declarations: [
                    %AST.VariableDeclarator{
                      init: %AST.CallExpression{
                        callee: %AST.FunctionExpression{
                          generator: true,
                          body: %AST.BlockStatement{
                            body: [
                              %AST.ExpressionStatement{
                                expression: %AST.AssignmentExpression{
                                  right: %AST.AssignmentExpression{
                                    left: %AST.ArrayPattern{
                                      elements: [
                                        %AST.AssignmentPattern{
                                          right: %AST.YieldExpression{}
                                        }
                                      ]
                                    }
                                  }
                                }
                              }
                            ]
                          }
                        }
                      }
                    }
                  ]
                }
              ]
            }} = Parser.parse("var iter = (function*() { result = [x = yield] = vals; })();")
  end

  test "treats yield as an identifier in non-generator function bodies" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{
                  body: %AST.BlockStatement{
                    body: [
                      %AST.VariableDeclaration{
                        declarations: [
                          %AST.VariableDeclarator{id: %AST.Identifier{name: "yield"}}
                        ]
                      }
                    ]
                  }
                }
              ]
            }} = Parser.parse("function f() { var yield = 1; }")
  end
end
