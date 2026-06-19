defmodule QuickBEAM.JS.Parser.Functions.YieldWithoutRhsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS yield without RHS before conditional colon" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{
                  body: %AST.BlockStatement{
                    body: [
                      %AST.ExpressionStatement{
                        expression: %AST.ConditionalExpression{
                          consequent: %AST.YieldExpression{argument: nil},
                          alternate: %AST.YieldExpression{argument: nil}
                        }
                      }
                    ]
                  },
                  generator: true
                }
              ]
            }} = Parser.parse("function* g() { (yield) ? yield : yield; }")
  end
end
