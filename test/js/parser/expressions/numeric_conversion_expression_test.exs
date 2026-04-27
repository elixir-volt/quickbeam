defmodule QuickBEAM.JS.Parser.Expressions.NumericConversionExpressionTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS numeric conversion expression syntax" do
    source = """
    NaN | 0;
    Infinity | 0;
    (-Infinity) | 0;
    "12345" >>> 0;
    (4294967296 * 3 - 4) >>> 0;
    """

    assert {:ok, %AST.Program{body: statements}} = Parser.parse(source)
    assert length(statements) == 5

    assert Enum.all?(statements, fn
             %AST.ExpressionStatement{expression: %AST.BinaryExpression{operator: operator}}
             when operator in ["|", ">>>"] ->
               true

             _ ->
               false
           end)

    assert %AST.ExpressionStatement{
             expression: %AST.BinaryExpression{
               operator: ">>>",
               left: %AST.BinaryExpression{operator: "-"}
             }
           } = List.last(statements)
  end
end
