defmodule QuickBEAM.JS.Parser.Diagnostics.AsyncAwaitParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS async function await parameter diagnostics" do
    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{async: true}]}, errors} =
             Parser.parse("async function f(await) {}")

    assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
  end

  test "ports QuickJS async arrow await parameter diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("fn = async (await) => await;")

    assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
  end
end
