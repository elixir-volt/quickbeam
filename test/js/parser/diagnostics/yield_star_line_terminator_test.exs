defmodule QuickBEAM.JS.Parser.Diagnostics.YieldStarLineTerminatorTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects line terminator before yield star delegate" do
    source = "async function *g() { yield\n* value; }"

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "yield delegate cannot start after line terminator"))
  end

  test "preserves same-line yield star delegate" do
    assert {:ok, %AST.Program{}} = Parser.parse("async function *g() { yield * value; }")
  end
end
