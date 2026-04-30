defmodule QuickBEAM.JS.Parser.Diagnostics.DestructuringAssignmentRestTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects assignment rest elements before additional elements" do
    for source <- [
          "0, [...x, y] = [];",
          "0, [...x,] = [];",
          "0, [...x, ,] = [];",
          "0, [...x, ...y] = [];",
          "0, {...rest, b} = {};"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid destructuring target"))
    end
  end

  test "rejects assignment rest element initializers" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("0, [...x = 1] = [];")
    assert Enum.any?(errors, &(&1.message == "invalid destructuring target"))
  end

  test "preserves nested assignment rest patterns" do
    for source <- ["0, [...[x]] = [];", "0, [...{x}] = [];"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
