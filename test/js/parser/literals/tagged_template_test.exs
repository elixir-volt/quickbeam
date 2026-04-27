defmodule QuickBEAM.JS.Parser.Literals.TaggedTemplateTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible tagged template syntax" do
    source = """
    value = tag`hello ${name}`;
    value = object.tag`hello`;
    """

    assert {:ok, %AST.Program{body: [plain_tag, member_tag]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.TaggedTemplateExpression{
                 tag: %AST.Identifier{name: "tag"},
                 quasi: %AST.TemplateLiteral{
                   quasis: [
                     %AST.TemplateElement{value: "hello "},
                     %AST.TemplateElement{value: "", tail: true}
                   ],
                   expressions: [%AST.Identifier{name: "name"}]
                 }
               }
             }
           } = plain_tag

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.TaggedTemplateExpression{
                 tag: %AST.MemberExpression{property: %AST.Identifier{name: "tag"}}
               }
             }
           } = member_tag
  end
end
