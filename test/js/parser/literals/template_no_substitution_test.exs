defmodule QuickBEAM.JS.Parser.Literals.TemplateNoSubstitutionTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible no-substitution template literal AST" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{expression: %AST.AssignmentExpression{right: template}}
              ]
            }} =
             Parser.parse("value = `plain text`;")

    assert %AST.TemplateLiteral{
             quasis: [%AST.TemplateElement{value: "plain text", raw: "plain text", tail: true}],
             expressions: []
           } = template
  end
end
