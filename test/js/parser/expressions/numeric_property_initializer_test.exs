defmodule QuickBEAM.JS.Parser.Expressions.NumericPropertyInitializerTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows numeric literal property initializers" do
    assert {:ok, %AST.Program{}} = Parser.parse("({ 0: 0 });")
  end

  test "keeps numeric literal shorthand invalid" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("({ 0 });")
    assert Enum.any?(errors, &(&1.message == "invalid object initializer"))
  end
end
