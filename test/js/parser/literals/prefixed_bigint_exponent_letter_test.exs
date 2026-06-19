defmodule QuickBEAM.JS.Parser.Literals.PrefixedBigIntExponentLetterTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "accepts prefixed BigInt literals containing exponent letters as digits" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.BinaryExpression{
                    operator: "+",
                    left: %AST.UnaryExpression{
                      operator: "-",
                      argument: %AST.Literal{raw: "0xFEDCBA9876543210n"}
                    },
                    right: %AST.UnaryExpression{
                      operator: "-",
                      argument: %AST.Literal{raw: "0x1FDB97530ECA86420n"}
                    }
                  }
                }
              ]
            }} = Parser.parse("-0xFEDCBA9876543210n + -0x1FDB97530ECA86420n;")
  end

  test "keeps decimal BigInt exponent forms invalid" do
    assert {:error, _program, errors} = Parser.parse("1e2n;")
    assert Enum.any?(errors, &(&1.message == "invalid bigint literal"))
  end
end
