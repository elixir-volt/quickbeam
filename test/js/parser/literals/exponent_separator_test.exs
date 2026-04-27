defmodule QuickBEAM.JS.Parser.Literals.ExponentSeparatorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible exponent numeric separator syntax" do
    source = """
    value = 1.5e1_0;
    other = 1e+1_2;
    """

    assert {:ok, %AST.Program{body: [first, second]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.Literal{value: 15_000_000_000.0, raw: "1.5e1_0"}
             }
           } = first

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.Literal{value: 1.0e12, raw: "1e+1_2"}
             }
           } = second
  end
end
