defmodule QuickBEAM.JS.Parser.ControlFlow.LabeledBlockFunctionTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows labeled function declarations inside sloppy blocks" do
    assert {:ok, %AST.Program{}} = Parser.parse("{ label: function f() {} }")
  end

  test "allows sloppy top-level labeled function declarations" do
    assert {:ok, %AST.Program{}} = Parser.parse("label: function f() {}")
    assert {:ok, %AST.Program{}} = Parser.parse("label1: label2: function f() {}")
  end

  test "rejects async and generator labeled function declarations" do
    for source <- ["label: async function f() {}", "label: function* f() {}"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "function declarations can't appear in single-statement context")
             )
    end
  end

  test "rejects labeled function declarations in strict scripts" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse(~S|"use strict"; label: function f() {}|)

    assert Enum.any?(
             errors,
             &(&1.message == "function declarations can't appear in single-statement context")
           )
  end
end
