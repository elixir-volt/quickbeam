defmodule QuickBEAM.JS.Parser.Literals.StringArgumentPunctuationValueTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "does not treat string argument values as delimiters" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.CallExpression{
                    arguments: [
                      %AST.Literal{raw: "'\\51'"},
                      %AST.Literal{value: ")"},
                      %AST.Literal{raw: "'\\\\51'"}
                    ]
                  }
                }
              ]
            }} = Parser.parse("assert.sameValue('\\51', '\\x29', '\\\\51');")
  end
end
