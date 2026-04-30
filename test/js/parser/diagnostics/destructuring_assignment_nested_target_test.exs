defmodule QuickBEAM.JS.Parser.Diagnostics.DestructuringAssignmentNestedTargetTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects sequence expressions inside nested assignment patterns" do
    for source <- ["0, [[(x, y)]] = [[]];", "0, { x: [(x, y)] } = { x: [] };"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid destructuring target"))
    end
  end

  test "rejects accessors inside nested assignment patterns" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("0, [{ get x() {} }] = [{}];")
    assert Enum.any?(errors, &(&1.message == "invalid destructuring target"))
  end
end
