defmodule QuickBEAM.JS.Parser.Diagnostics.StrictNestedFunctionExpressionBindingTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects restricted bindings inside nested function expressions in strict code" do
    for source <- [
          ~S|"use strict"; (function() { var yield; });|,
          ~S|class C { async *m() { return { ...(function() { var yield; }()) }; } }|
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
    end
  end
end
