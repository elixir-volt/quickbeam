defmodule QuickBEAM.JS.Parser.Diagnostics.AsyncGeneratorExpressionParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS async generator expression parameter diagnostics" do
    source = "value = async function *g(await, { yield }) {};"

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
    assert Enum.any?(errors, &(&1.message == "yield parameter not allowed in generator function"))
  end
end
