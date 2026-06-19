defmodule QuickBEAM.JS.Parser.Classes.GeneratorMethodYieldNameTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows yield as generator class method name" do
    assert {:ok, %AST.Program{}} = Parser.parse("class A { *yield() { yield 1; } }")
  end

  test "rejects yield as function expression name inside strict class method bodies" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse("class A { *g() { (function yield() {}); } }")

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end

  test "rejects yield assignment in nested function declarations inside strict class method bodies" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse("class A { *g() { function h() { yield = 1; } } }")

    assert Enum.any?(errors, &(&1.message == "restricted assignment target in strict mode"))
  end
end
