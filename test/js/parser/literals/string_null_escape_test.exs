defmodule QuickBEAM.JS.Parser.Literals.StringNullEscapeTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible string null escape syntax" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(~S(value = "a\0b";))

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{right: %AST.Literal{value: <<?a, 0, ?b>>}}
           } = statement
  end
end
