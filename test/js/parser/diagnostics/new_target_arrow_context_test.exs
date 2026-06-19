defmodule QuickBEAM.JS.Parser.Diagnostics.NewTargetArrowContextTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects new.target inside arrows in global code" do
    for source <- ["() => { new.target; };", "() => new.target;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "new.target not allowed outside function"))
    end
  end

  test "allows new.target inside normal functions" do
    assert {:ok, %AST.Program{}} = Parser.parse("function f() { new.target; }")
  end
end
