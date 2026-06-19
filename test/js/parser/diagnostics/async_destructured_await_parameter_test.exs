defmodule QuickBEAM.JS.Parser.Diagnostics.AsyncDestructuredAwaitParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS async destructured await parameter diagnostics" do
    source = "async function f({ await }) {}"

    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{async: true}]}, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
  end
end
