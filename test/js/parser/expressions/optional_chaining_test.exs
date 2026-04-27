defmodule QuickBEAM.JS.Parser.Expressions.OptionalChainingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS optional chaining member call and computed syntax" do
    source = """
    a?.b;
    a?.b();
    a?.["b"]();
    delete a?.b["c"];
    """

    assert {:ok, %AST.Program{body: [member, call, computed_call, delete_expr]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.MemberExpression{optional: true, computed: false}
           } = member

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{callee: %AST.MemberExpression{optional: true}}
           } = call

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.MemberExpression{optional: true, computed: true}
             }
           } = computed_call

    assert %AST.ExpressionStatement{
             expression: %AST.UnaryExpression{
               operator: "delete",
               argument: %AST.MemberExpression{object: %AST.MemberExpression{optional: true}}
             }
           } = delete_expr
  end
end
