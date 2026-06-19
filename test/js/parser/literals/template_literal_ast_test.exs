defmodule QuickBEAM.JS.Parser.Literals.TemplateLiteralASTTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible template literal quasis and expressions" do
    assert {:ok, %AST.Program{body: [statement]}} =
             Parser.parse("value = `hello ${name}, ${count + 1}!`;")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.TemplateLiteral{
                 quasis: [
                   %AST.TemplateElement{value: "hello ", tail: false},
                   %AST.TemplateElement{value: ", ", tail: false},
                   %AST.TemplateElement{value: "!", tail: true}
                 ],
                 expressions: [
                   %AST.Identifier{name: "name"},
                   %AST.BinaryExpression{
                     operator: "+",
                     left: %AST.Identifier{name: "count"},
                     right: %AST.Literal{value: 1}
                   }
                 ]
               }
             }
           } = statement
  end

  test "ports QuickJS-compatible tagged template literal AST" do
    assert {:ok, %AST.Program{body: [%AST.ExpressionStatement{expression: tagged}]}} =
             Parser.parse("tag`hello ${name}`;")

    assert %AST.TaggedTemplateExpression{
             tag: %AST.Identifier{name: "tag"},
             quasi: %AST.TemplateLiteral{
               quasis: [
                 %AST.TemplateElement{value: "hello "},
                 %AST.TemplateElement{value: "", tail: true}
               ],
               expressions: [%AST.Identifier{name: "name"}]
             }
           } = tagged
  end
end
