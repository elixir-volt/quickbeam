defmodule QuickBEAM.JS.Parser.Expressions.ObjectMethodSuperTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows super property access inside object methods and accessors" do
    for source <- [
          "object = { method() { return super.x; } };",
          "object = { get value() { return super.x; } };",
          "object = { set value(v) { super.x = v; } };"
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "still rejects super calls inside object methods" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("object = { method() { super(); } };")
    assert Enum.any?(errors, &(&1.message == "super not allowed outside class method"))
  end
end
