defmodule QuickBEAM.JS.Parser.Diagnostics.AsyncParameterAwaitExpressionTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects await expressions in async function parameter defaults" do
    for source <- [
          "async function f(x = await 1) {}",
          "value = async function*(x = await 1) {};",
          "value = async (x = await 1) => x;"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
    end
  end
end
