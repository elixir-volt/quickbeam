defmodule QuickBEAM.JS.Parser.Diagnostics.BlockFunctionStrictRedeclarationTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects duplicate block function declarations in strict scripts" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse(~S|"use strict"; { function f() {} function f() {} }|)

    assert Enum.any?(errors, &(&1.message == "duplicate lexical declaration"))
  end

  test "allows nested block lexical declarations to shadow function parameters" do
    assert {:ok, %AST.Program{}} = Parser.parse("function fn(a) { { let a = 1; } }")
  end
end
