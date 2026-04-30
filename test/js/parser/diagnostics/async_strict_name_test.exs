defmodule QuickBEAM.JS.Parser.Diagnostics.AsyncStrictNameTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows restricted async function names outside strict mode" do
    for source <- ["value = async function eval() {};", "value = async function *arguments() {};"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "allows restricted async function parameters outside strict mode" do
    for source <- ["async function f(eval) {}", "value = async (arguments) => arguments;"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "rejects restricted async function parameters when the body is strict" do
    source = ~S|value = async (arguments) => { "use strict"; return arguments; };|

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "restricted parameter name in strict mode"))
  end
end
