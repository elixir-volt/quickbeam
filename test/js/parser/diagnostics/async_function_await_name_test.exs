defmodule QuickBEAM.JS.Parser.Diagnostics.AsyncFunctionAwaitNameTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows await as an async function name in script code" do
    assert {:ok, %AST.Program{}} = Parser.parse("async function await() { return 1; }")
  end

  test "rejects await as an async generator function name" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("value = async function *await() {};")
    assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
  end
end
