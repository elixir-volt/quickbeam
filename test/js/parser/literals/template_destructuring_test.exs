defmodule QuickBEAM.JS.Parser.Literals.TemplateDestructuringTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS template skip destructuring declaration shape" do
    assert {:ok, %AST.Program{body: [statement]}} =
             Parser.parse(~s|var { b = `${a + `a${a}` }baz` } = {};|)

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{
                 id: %AST.ObjectPattern{
                   properties: [
                     %AST.Property{
                       key: %AST.Identifier{name: "b"},
                       value: %AST.AssignmentPattern{
                         right: %AST.TemplateLiteral{
                           quasis: [
                             %AST.TemplateElement{value: ""},
                             %AST.TemplateElement{value: "baz", tail: true}
                           ],
                           expressions: [%AST.BinaryExpression{right: %AST.TemplateLiteral{}}]
                         }
                       }
                     }
                   ]
                 },
                 init: %AST.ObjectExpression{properties: []}
               }
             ]
           } = statement
  end
end
