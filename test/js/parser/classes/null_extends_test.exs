defmodule QuickBEAM.JS.Parser.Classes.NullExtendsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible class extends null syntax" do
    source = """
    class D extends null {}
    value = class extends null {};
    """

    assert {:ok, %AST.Program{body: [declaration, expression]}} = Parser.parse(source)

    assert %AST.ClassDeclaration{
             id: %AST.Identifier{name: "D"},
             super_class: %AST.Literal{value: nil, raw: "null"}
           } = declaration

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ClassExpression{super_class: %AST.Literal{value: nil, raw: "null"}}
             }
           } = expression
  end
end
