defmodule QuickBEAM.JS.Parser.Literals.RegExpTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS regexp skip after assignment in array pattern-like syntax" do
    for source <- ["[a, b = /abc\\(/] = [1];", "[a, b =/abc\\(/] = [2];"] do
      assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

      assert %AST.ExpressionStatement{
               expression: %AST.AssignmentExpression{
                 left: %AST.ArrayPattern{
                   elements: [_, %AST.AssignmentPattern{right: regex}]
                 }
               }
             } = statement

      assert %AST.Literal{value: %{pattern: "abc\\(", flags: ""}} = regex
    end
  end
end
