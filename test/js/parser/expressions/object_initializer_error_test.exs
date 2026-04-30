defmodule QuickBEAM.JS.Parser.Expressions.ObjectInitializerErrorTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects cover initialized names in object literals" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("({ a = 1 });")
    assert Enum.any?(errors, &(&1.message == "invalid object initializer"))
  end

  test "rejects non-identifier shorthand property names" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("({ 0 });")
    assert Enum.any?(errors, &(&1.message == "invalid object initializer"))
  end

  test "preserves object assignment pattern defaults" do
    assert {:ok, %AST.Program{}} = Parser.parse("({ a = 1 } = obj);")
  end
end
