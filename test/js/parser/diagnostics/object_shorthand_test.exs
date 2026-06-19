defmodule QuickBEAM.JS.Parser.Diagnostics.ObjectShorthandTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects computed property shorthand" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("({[x]});")
    assert Enum.any?(errors, &(&1.message == "invalid object shorthand"))
  end

  test "rejects restricted object shorthand in strict code" do
    for source <- [~S|"use strict"; ({ let });|, ~S|function f() { "use strict"; ({ public }); }|] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid object shorthand"))
    end
  end

  test "rejects await object shorthand in await context" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("class C { static { ({ await }); } }")
    assert Enum.any?(errors, &(&1.message == "invalid object shorthand"))
  end
end
