defmodule QuickBEAM.JS.Parser.Literals.TemplateTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS template and tagged template parsing" do
    assert {:ok, %AST.Program{body: [plain, tagged]}} =
             Parser.parse("a = `abc${b}d`; String.raw `abc${b}d`;")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.TemplateLiteral{
                 quasis: [
                   %AST.TemplateElement{value: "abc"},
                   %AST.TemplateElement{value: "d", tail: true}
                 ],
                 expressions: [%AST.Identifier{name: "b"}]
               }
             }
           } = plain

    assert %AST.ExpressionStatement{
             expression: %AST.TaggedTemplateExpression{quasi: %AST.TemplateLiteral{}}
           } =
             tagged
  end

  test "ports QuickJS nested template skip parsing" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("var b = `${a + `a${a}` }baz`;")

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{
                 init: %AST.TemplateLiteral{
                   quasis: [
                     %AST.TemplateElement{value: ""},
                     %AST.TemplateElement{value: "baz", tail: true}
                   ],
                   expressions: [%AST.BinaryExpression{right: %AST.TemplateLiteral{}}]
                 }
               }
             ]
           } = statement
  end
end
