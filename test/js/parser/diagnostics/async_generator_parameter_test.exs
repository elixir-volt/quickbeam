defmodule QuickBEAM.JS.Parser.Diagnostics.AsyncGeneratorParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS async generator await parameter diagnostics" do
    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{async: true, generator: true}]},
            errors} =
             Parser.parse("async function *g(await) {}")

    assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
  end

  test "ports QuickJS async generator yield parameter diagnostics" do
    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{async: true, generator: true}]},
            errors} =
             Parser.parse("async function *g({ yield }) {}")

    assert Enum.any?(errors, &(&1.message == "yield parameter not allowed in generator function"))
  end
end
