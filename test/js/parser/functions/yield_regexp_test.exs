defmodule QuickBEAM.JS.Parser.Functions.YieldRegexpTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS yield regexp expression syntax" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{
                  body: %AST.BlockStatement{
                    body: [
                      %AST.ExpressionStatement{
                        expression: %AST.AssignmentExpression{
                          right: %AST.YieldExpression{argument: %AST.Literal{raw: "/abc/i"}}
                        }
                      }
                    ]
                  },
                  generator: true
                }
              ]
            }} = Parser.parse("function* g() { received = yield/abc/i; }")
  end
end
