defmodule QuickBEAM.JS.Parser.Expressions.AsyncGeneratorComputedMethodTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS async generator computed object methods" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{
                  declarations: [
                    %AST.VariableDeclarator{
                      init: %AST.MemberExpression{
                        object: %AST.ObjectExpression{
                          properties: [
                            %AST.Property{
                              method: true,
                              computed: true,
                              value: %AST.FunctionExpression{async: true, generator: true}
                            }
                          ]
                        }
                      }
                    }
                  ]
                }
              ]
            }} = Parser.parse(~s|let g = { async * ["g"]() {} }.g;|)
  end
end
