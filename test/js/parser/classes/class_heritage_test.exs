defmodule QuickBEAM.JS.Parser.Classes.ClassHeritageTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects unparenthesized arrow functions in class heritage" do
    for source <- [
          "var C = class extends () => {} {};",
          "var C = class extends async () => {} {};"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid class heritage"))
    end
  end

  test "allows parenthesized arrow functions in class heritage" do
    for source <- [
          "var C = class extends (() => {}) {};",
          "var C = class extends (async () => {}) {};"
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
