defmodule QuickBEAM.JS.Parser.Diagnostics.StrictWithObjectMethodTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects with statements in object methods under script strict mode" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse("\"use strict\"; var obj = { get value() { with (obj) {} } };")

    assert Enum.any?(errors, &(&1.message == "with statement not allowed in strict mode"))
  end
end
