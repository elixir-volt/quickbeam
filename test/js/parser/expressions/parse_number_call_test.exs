defmodule QuickBEAM.JS.Parser.Expressions.ParseNumberCallTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS parseInt and parseFloat call syntax" do
    source = """
    parseInt("0_1");
    parseInt("1_0", 8);
    parseFloat("Infinity.");
    parseFloat("Infinity_");
    """

    assert {:ok, %AST.Program{body: statements}} = Parser.parse(source)
    assert length(statements) == 4

    assert Enum.all?(statements, fn
             %AST.ExpressionStatement{
               expression: %AST.CallExpression{callee: %AST.Identifier{name: name}}
             }
             when name in ["parseInt", "parseFloat"] ->
               true

             _ ->
               false
           end)

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               arguments: [%AST.Literal{value: "1_0"}, %AST.Literal{value: 8}]
             }
           } = Enum.at(statements, 1)
  end
end
