defmodule QuickBEAM.JS.Parser.Literals.StringCrlfContinuationTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible string CRLF line continuation syntax" do
    source = "value = \"a\\\r\nb\";"

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{right: %AST.Literal{value: "ab"}}
           } = statement
  end
end
