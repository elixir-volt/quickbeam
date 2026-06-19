defmodule QuickBEAM.JS.Parser.Diagnostics.DestructuringAssignmentTargetTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects reserved shorthand identifiers in object assignment patterns" do
    for source <- [
          "var x = { break } = value;",
          "var x = { default } = value;",
          "var x = { tr\\u0079 } = value;"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid destructuring target"))
    end
  end

  test "rejects yield shorthand in generator object assignment patterns" do
    source = "function* g() { 0, { yield } = value; }"

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "invalid destructuring target"))
  end

  test "preserves named properties in object assignment patterns" do
    assert {:ok, %AST.Program{}} = Parser.parse("var value; ({ default: value } = object);")
  end
end
