defmodule QuickBEAM.JS.Parser.Diagnostics.StrictWithFunctionBodyTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects with statements in nested function expressions under script strict mode" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse("\"use strict\"; var f = function () { with (o) {} };")

    assert Enum.any?(errors, &(&1.message == "with statement not allowed in strict mode"))
  end
end
