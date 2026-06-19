defmodule QuickBEAM.JS.Parser.Classes.AsyncMethodSuperCallParamTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects direct super calls in async class method parameter defaults" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse("class A { async method(x = super()) {} }")

    assert Enum.any?(errors, &(&1.message == "super not allowed outside class method"))
  end

  test "allows super property calls in async class method parameter defaults" do
    assert {:ok, %AST.Program{}} =
             Parser.parse("class B extends A { async method(x = super.method()) {} }")
  end
end
