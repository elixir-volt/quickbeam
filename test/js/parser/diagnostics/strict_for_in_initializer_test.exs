defmodule QuickBEAM.JS.Parser.Diagnostics.StrictForInInitializerTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects var for-in initializers in strict scripts" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse(~S|"use strict"; for (var a = 0 in object) {}|)

    assert Enum.any?(errors, &(&1.message =~ "initializer"))
  end

  test "continues allowing sloppy var identifier for-in initializers" do
    assert {:ok, %AST.Program{}} = Parser.parse("for (var a = 0 in object) {}")
  end
end
