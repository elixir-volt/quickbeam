defmodule QuickBEAM.JS.Parser.Diagnostics.YieldUnaryOperandTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects yield as a unary operand in generator bodies" do
    for source <- ["function *g() { void yield; }", "async function *g() { void yi\\u0065ld; }"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "yield expression not allowed as unary operand"))
    end
  end
end
