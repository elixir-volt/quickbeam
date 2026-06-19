defmodule QuickBEAM.JS.Parser.Literals.StringPunctuationExpressionTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "parses string literals whose values look like grouping punctuation" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ThrowStatement{
                  argument: %AST.NewExpression{
                    arguments: [
                      %AST.BinaryExpression{
                        operator: "+",
                        left: %AST.BinaryExpression{
                          operator: "+",
                          left: %AST.Literal{value: "("}
                        },
                        right: %AST.Literal{value: ")"}
                      }
                    ]
                  }
                }
              ]
            }} = Parser.parse(~s|throw new Test262Error("(" + value + ")");|)
  end
end
