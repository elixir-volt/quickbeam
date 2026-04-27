defmodule QuickBEAM.JS.Parser.Functions.ArrowBodyCommaTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "arrow concise body does not consume object property separators" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.ObjectExpression{
                    properties: [
                      %AST.Property{
                        key: %AST.Identifier{name: "get"},
                        value: %AST.ArrowFunctionExpression{body: %AST.Literal{value: "bar"}}
                      },
                      %AST.Property{key: %AST.Identifier{name: "enumerable"}}
                    ]
                  }
                }
              ]
            }} = Parser.parse(~s|({ get: () => "bar", enumerable: true });|)
  end

  test "arrow expression is lower precedence than comma expression" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.SequenceExpression{
                    expressions: [
                      %AST.ArrowFunctionExpression{body: %AST.Identifier{name: "a"}},
                      %AST.Identifier{name: "b"}
                    ]
                  }
                }
              ]
            }} = Parser.parse("x => a, b;")
  end
end
