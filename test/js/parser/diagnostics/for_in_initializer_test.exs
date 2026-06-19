defmodule QuickBEAM.JS.Parser.Diagnostics.ForInInitializerTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS for-in initializer diagnostics" do
    for source <- [
          "for (a = 0 in object) {}",
          "for (var [a] = 0 in object) {}",
          "for (var {a} = value in object) {}"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message =~ "initializer"))
    end
  end

  test "ports QuickJS multiple binding diagnostics in for-in/of declarations" do
    for source <- ["for (let x, y in object) {}", "for (const x, y of values) {}"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "expected 'of' or 'in' in for control expression"))
    end
  end

  test "preserves QuickJS-compatible sloppy var identifier initializer" do
    assert {:ok, %AST.Program{}} = Parser.parse("for (var a = 0 in object) {}")
  end
end
