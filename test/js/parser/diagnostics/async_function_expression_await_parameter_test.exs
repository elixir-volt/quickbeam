defmodule QuickBEAM.JS.Parser.Diagnostics.AsyncFunctionExpressionAwaitParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS async function expression await parameter diagnostics" do
    source = "value = async function named(await) {};"

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
  end
end
