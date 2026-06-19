defmodule QuickBEAM.JS.Parser.Literals.StringEscapeTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible string escape syntax" do
    source = ~s|value = "\\x61\\u0062\\u{63}";|

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{right: %AST.Literal{value: "abc"}}
           } = statement
  end
end
