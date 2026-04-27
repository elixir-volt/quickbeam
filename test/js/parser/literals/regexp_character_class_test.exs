defmodule QuickBEAM.JS.Parser.Literals.RegexpCharacterClassTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible regexp character class slash syntax" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("pattern = /[/\\]a-z]+/gi;")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.Literal{
                 value: %{pattern: "[/\\]a-z]+", flags: "gi"},
                 raw: "/[/\\]a-z]+/gi"
               }
             }
           } = statement
  end
end
