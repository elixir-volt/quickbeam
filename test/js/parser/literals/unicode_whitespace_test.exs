defmodule QuickBEAM.JS.Parser.Literals.UnicodeWhitespaceTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "skips non-ascii ECMAScript whitespace and line separators" do
    source =
      "assert.sameValue(x\t\v\f \u00A0\n\r\u2028\u2029+=\t\v\f \u00A0\n\r\u2028\u2029-1, -2);"

    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.CallExpression{
                    arguments: [
                      %AST.AssignmentExpression{operator: "+="},
                      %AST.UnaryExpression{operator: "-"}
                    ]
                  }
                }
              ]
            }} = Parser.parse(source)
  end
end
