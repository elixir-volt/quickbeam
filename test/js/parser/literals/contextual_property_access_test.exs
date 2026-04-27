defmodule QuickBEAM.JS.Parser.Literals.ContextualPropertyAccessTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS contextual object property access syntax" do
    source = """
    a = { x: 1, if: 2, async: 3 };
    a.if === 2;
    a.async === 3;
    """

    assert {:ok, %AST.Program{body: [assignment, if_access, async_access]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{
                 properties: [
                   %AST.Property{key: %AST.Identifier{name: "x"}},
                   %AST.Property{key: %AST.Identifier{name: "if"}},
                   %AST.Property{key: %AST.Identifier{name: "async"}}
                 ]
               }
             }
           } = assignment

    assert %AST.ExpressionStatement{
             expression: %AST.BinaryExpression{
               left: %AST.MemberExpression{property: %AST.Identifier{name: "if"}},
               operator: "==="
             }
           } = if_access

    assert %AST.ExpressionStatement{
             expression: %AST.BinaryExpression{
               left: %AST.MemberExpression{property: %AST.Identifier{name: "async"}},
               operator: "==="
             }
           } = async_access
  end
end
