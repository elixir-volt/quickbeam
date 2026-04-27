defmodule QuickBEAM.JS.Parser.Expressions.StrictEqualityLogicalTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict equality logical syntax" do
    source = """
    r === 1 && a === 2;
    r === 0 && a === 0;
    a.x === 2 && a[0] === 2;
    """

    assert {:ok, %AST.Program{body: statements}} = Parser.parse(source)
    assert length(statements) == 3

    assert Enum.all?(statements, fn
             %AST.ExpressionStatement{
               expression: %AST.LogicalExpression{
                 operator: "&&",
                 left: %AST.BinaryExpression{operator: "==="},
                 right: %AST.BinaryExpression{operator: "==="}
               }
             } ->
               true

             _ ->
               false
           end)

    assert %AST.ExpressionStatement{
             expression: %AST.LogicalExpression{
               left: %AST.BinaryExpression{left: %AST.MemberExpression{computed: false}},
               right: %AST.BinaryExpression{left: %AST.MemberExpression{computed: true}}
             }
           } = List.last(statements)
  end
end
