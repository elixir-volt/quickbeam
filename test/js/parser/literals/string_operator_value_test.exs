defmodule QuickBEAM.JS.Parser.Literals.StringOperatorValueTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "parses strings whose values match update operators as literals" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.CallExpression{
                    arguments: [
                      %AST.Literal{value: "++"},
                      %AST.Literal{value: "--"}
                    ]
                  }
                }
              ]
            }} = Parser.parse(~s|assert("++", "--");|)
  end

  test "parses strings whose values match unary keywords as literals" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.CallExpression{
                    arguments: [
                      %AST.Literal{value: "delete"},
                      %AST.Literal{value: "typeof"},
                      %AST.Literal{value: "void"}
                    ]
                  }
                }
              ]
            }} = Parser.parse(~s|assert("delete", "typeof", "void");|)
  end
end
