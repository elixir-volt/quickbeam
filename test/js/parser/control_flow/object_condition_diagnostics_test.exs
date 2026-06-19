defmodule QuickBEAM.JS.Parser.ControlFlow.ObjectConditionDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects invalid object literal forms in statement conditions" do
    for source <- ["if ({1}) {}", "while ({1}) {}", "switch ({1}) { case 0: ; }"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid object initializer"))
    end
  end

  test "rejects statements before the first switch clause" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse("switch (value) { value = 1; case 1: ; }")

    assert Enum.any?(errors, &(&1.message == "invalid switch statement"))
  end
end
