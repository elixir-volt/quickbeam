defmodule QuickBEAM.JS.Parser.Literals.BigIntLiteralTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible bigint literal syntax" do
    source = """
    decimal = 123n;
    hex = 0xfn;
    binary = 0b101n;
    octal = 0o77n;
    """

    assert {:ok, %AST.Program{body: statements}} = Parser.parse(source)

    assert Enum.map(statements, fn
             %AST.ExpressionStatement{
               expression: %AST.AssignmentExpression{right: %AST.Literal{value: value, raw: raw}}
             } ->
               {value, raw}
           end) == [{123, "123n"}, {15, "0xfn"}, {5, "0b101n"}, {63, "0o77n"}]
  end

  test "ports QuickJS invalid decimal bigint syntax" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("value = 1.2n;")
    assert Enum.any?(errors, &(&1.message == "invalid bigint literal"))
  end
end
