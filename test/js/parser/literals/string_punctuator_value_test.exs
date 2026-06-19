defmodule QuickBEAM.JS.Parser.Literals.StringPunctuatorValueTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "parses strings whose values match private-name punctuators as literals" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.BinaryExpression{
                    operator: "+",
                    left: %AST.Literal{value: "#"},
                    right: %AST.Identifier{name: "i"}
                  }
                }
              ]
            }} = Parser.parse(~s|"#" + i;|)
  end
end
