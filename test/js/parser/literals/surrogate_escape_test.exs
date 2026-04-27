defmodule QuickBEAM.JS.Parser.Literals.SurrogateEscapeTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "accepts lone surrogate fixed unicode escapes in strings" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.BinaryExpression{
                    operator: ">",
                    left: %AST.Literal{},
                    right: %AST.Literal{}
                  }
                }
              ]
            }} = Parser.parse(~S|"\uDC00" > "\uD800";|)
  end
end
