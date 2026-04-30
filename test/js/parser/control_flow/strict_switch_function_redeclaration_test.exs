defmodule QuickBEAM.JS.Parser.ControlFlow.StrictSwitchFunctionRedeclarationTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects duplicate switch function declarations in strict scripts" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse(
               ~S|"use strict"; switch (x) { case 0: function f() {} default: function f() {} }|
             )

    assert Enum.any?(errors, &(&1.message == "duplicate lexical declaration"))
  end
end
