defmodule QuickBEAM.JS.Parser.Expressions.NullishLogicalTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible nullish coalescing and logical assignment syntax" do
    source = """
    value = fallback ?? defaultValue;
    value ??= defaultValue;
    value ||= defaultValue;
    value &&= defaultValue;
    """

    assert {:ok, %AST.Program{body: [coalesce, nullish_assign, or_assign, and_assign]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{right: %AST.LogicalExpression{operator: "??"}}
           } = coalesce

    assert %AST.ExpressionStatement{expression: %AST.AssignmentExpression{operator: "??="}} =
             nullish_assign

    assert %AST.ExpressionStatement{expression: %AST.AssignmentExpression{operator: "||="}} =
             or_assign

    assert %AST.ExpressionStatement{expression: %AST.AssignmentExpression{operator: "&&="}} =
             and_assign
  end
end
