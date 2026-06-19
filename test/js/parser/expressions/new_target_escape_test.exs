defmodule QuickBEAM.JS.Parser.Expressions.NewTargetEscapeTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects escaped new.target meta-property keywords" do
    for source <- ["function f() { \\u006eew.target; }", "function f() { new.\\u0074arget; }"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid meta property"))
    end
  end

  test "allows literal new.target" do
    assert {:ok, %AST.Program{}} = Parser.parse("function f() { new.target; }")
  end
end
