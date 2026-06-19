defmodule QuickBEAM.JS.Parser.Diagnostics.StrictYieldParameterInitializerTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects yield parameter defaults in strict function expressions" do
    source = ~S|"use strict"; function *g() { 0, function(x = yield) {}; }|

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "yield parameter not allowed in generator function"))
  end

  test "parses yield as an identifier in non-generator function parameters outside strict code" do
    source = "function *g() { 0, function(x = yield) {}; }"

    assert {:ok, %AST.Program{}} = Parser.parse(source)
  end
end
