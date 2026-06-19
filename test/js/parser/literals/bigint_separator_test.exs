defmodule QuickBEAM.JS.Parser.Literals.BigIntSeparatorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible bigint numeric separator syntax" do
    source = """
    decimal = 1_000n;
    hex = 0xff_ffn;
    binary = 0b1010_0101n;
    """

    assert {:ok, %AST.Program{body: statements}} = Parser.parse(source)

    assert Enum.map(statements, fn
             %AST.ExpressionStatement{
               expression: %AST.AssignmentExpression{right: %AST.Literal{value: value, raw: raw}}
             } ->
               {value, raw}
           end) == [{1000, "1_000n"}, {65_535, "0xff_ffn"}, {165, "0b1010_0101n"}]
  end
end
