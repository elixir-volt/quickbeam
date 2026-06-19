defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleAsyncGeneratorParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module async generator await parameter diagnostics" do
    assert {:error,
            %AST.Program{
              source_type: :module,
              body: [%AST.FunctionDeclaration{async: true, generator: true}]
            }, errors} =
             Parser.parse("async function *g(await) {}", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "expected binding identifier"))
  end

  test "ports QuickJS module async generator yield parameter diagnostics" do
    assert {:error,
            %AST.Program{
              source_type: :module,
              body: [%AST.FunctionDeclaration{async: true, generator: true}]
            }, errors} =
             Parser.parse("async function *g({ yield }) {}", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "yield parameter not allowed in generator function"))
  end
end
