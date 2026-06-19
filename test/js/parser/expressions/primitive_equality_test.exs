defmodule QuickBEAM.JS.Parser.Expressions.PrimitiveEqualityTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS primitive equality expression syntax" do
    source = """
    null == undefined;
    undefined == null;
    true == 1;
    0 == false;
    "" == 0;
    "123" == 123;
    "122" != 123;
    ({} != "abc");
    """

    assert {:ok, %AST.Program{body: statements}} = Parser.parse(source)
    assert length(statements) == 8

    assert Enum.all?(statements, fn
             %AST.ExpressionStatement{expression: %AST.BinaryExpression{operator: operator}}
             when operator in ["==", "!="] ->
               true

             _ ->
               false
           end)

    assert %AST.ExpressionStatement{
             expression: %AST.BinaryExpression{
               left: %AST.Literal{value: nil},
               right: %AST.Identifier{name: "undefined"}
             }
           } = hd(statements)

    assert %AST.ExpressionStatement{
             expression: %AST.BinaryExpression{left: %AST.ObjectExpression{}, operator: "!="}
           } = List.last(statements)
  end
end
