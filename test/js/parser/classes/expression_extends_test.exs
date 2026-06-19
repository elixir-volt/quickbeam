defmodule QuickBEAM.JS.Parser.Classes.ExpressionExtendsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible class extends expression syntax" do
    source = """
    class D extends mixin(Base) {}
    value = class extends namespace.Base {};
    """

    assert {:ok, %AST.Program{body: [declaration, expression]}} = Parser.parse(source)

    assert %AST.ClassDeclaration{
             id: %AST.Identifier{name: "D"},
             super_class: %AST.CallExpression{callee: %AST.Identifier{name: "mixin"}}
           } = declaration

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ClassExpression{
                 super_class: %AST.MemberExpression{object: %AST.Identifier{name: "namespace"}}
               }
             }
           } = expression
  end
end
