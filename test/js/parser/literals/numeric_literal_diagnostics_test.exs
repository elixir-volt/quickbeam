defmodule QuickBEAM.JS.Parser.Literals.NumericLiteralDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects numeric literals followed by identifier starts" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("3in []")
    assert Enum.any?(errors, &(&1.message == "invalid number literal"))
  end

  test "rejects legacy-octal-like bigint literals" do
    for source <- ["00n;", "01n;", "07n;", "08n;", "09n;", "012348n;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid number literal"))
    end
  end

  test "rejects decimal separators adjacent to dot or exponent" do
    for source <- [".0_e1", "1.0_e1", "1._0", "1_.0", "1e_1", "1e+_1"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid number literal"))
    end
  end
end
