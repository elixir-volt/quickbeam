defmodule QuickBEAM.JS.Parser.Literals.NumberLiteralTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS numeric separator parsing" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("value = 1_0;")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{right: %AST.Literal{value: 10}}
           } = statement
  end

  test "ports QuickJS invalid legacy numeric separator cases" do
    for source <- ["0_0", "00_0", "01_0", "08_0", "09_0"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid numeric separator"))
    end
  end

  test "ports QuickJS invalid dotted number literal syntax" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("0.a")
    assert Enum.any?(errors, &(&1.message == "invalid number literal"))
  end

  test "keeps valid dotted number literal syntax" do
    assert {:ok,
            %AST.Program{body: [%AST.ExpressionStatement{expression: %AST.Literal{value: value}}]}} =
             Parser.parse("0.;")

    assert value == 0.0
  end
end
