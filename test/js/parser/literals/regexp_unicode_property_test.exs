defmodule QuickBEAM.JS.Parser.Literals.RegexpUnicodePropertyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible regexp unicode property syntax" do
    assert {:ok, %AST.Program{body: [statement]}} =
             Parser.parse(~S(pattern = /\p{Script=Greek}+/u;))

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.Literal{value: %{pattern: ~S(\p{Script=Greek}+), flags: "u"}}
             }
           } = statement
  end
end
