defmodule QuickBEAM.JS.Parser.Diagnostics.ExponentiationUnaryBaseTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects unparenthesized unary expressions as exponentiation bases" do
    for source <- [
          "-x ** y;",
          "+x ** y;",
          "typeof x ** y;",
          "!x ** y;",
          "~x ** y;",
          "void x ** y;",
          "delete x ** y;"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "unparenthesized unary expression cannot be exponentiation base")
             )
    end
  end

  test "allows parenthesized unary exponentiation bases" do
    assert {:ok, %AST.Program{}} = Parser.parse("(-x) ** y;")
  end
end
