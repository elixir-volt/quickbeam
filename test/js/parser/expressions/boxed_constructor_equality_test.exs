defmodule QuickBEAM.JS.Parser.Expressions.BoxedConstructorEqualityTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS boxed constructor equality syntax" do
    source = """
    (new Number(1)) == 1;
    2 == (new Number(2));
    (new String("abc")) == "abc";
    """

    assert {:ok, %AST.Program{body: [number_left, number_right, string_left]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.BinaryExpression{
               operator: "==",
               left: %AST.NewExpression{callee: %AST.Identifier{name: "Number"}}
             }
           } = number_left

    assert %AST.ExpressionStatement{
             expression: %AST.BinaryExpression{
               operator: "==",
               right: %AST.NewExpression{callee: %AST.Identifier{name: "Number"}}
             }
           } = number_right

    assert %AST.ExpressionStatement{
             expression: %AST.BinaryExpression{
               operator: "==",
               left: %AST.NewExpression{callee: %AST.Identifier{name: "String"}}
             }
           } = string_left
  end
end
