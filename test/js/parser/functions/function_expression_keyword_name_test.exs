defmodule QuickBEAM.JS.Parser.Functions.FunctionExpressionKeywordNameTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "allows await as a function expression name and parameter in script class static blocks" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ClassDeclaration{
                  body: [
                    %AST.StaticBlock{
                      body: [
                        %AST.ExpressionStatement{
                          expression: %AST.FunctionExpression{
                            id: %AST.Identifier{name: "await"},
                            params: [%AST.Identifier{name: "await"}]
                          }
                        }
                      ]
                    }
                  ]
                }
              ]
            }} = Parser.parse("class C { static { (function await(await) {}); } }")
  end

  test "allows yield as a function expression name inside generator bodies" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{
                  declarations: [
                    %AST.VariableDeclarator{
                      init: %AST.FunctionExpression{
                        generator: true,
                        body: %AST.BlockStatement{
                          body: [
                            %AST.ExpressionStatement{
                              expression: %AST.FunctionExpression{
                                id: %AST.Identifier{name: "yield"}
                              }
                            }
                          ]
                        }
                      }
                    }
                  ]
                }
              ]
            }} = Parser.parse("var g = function*() { (function yield() {}); };")
  end
end
