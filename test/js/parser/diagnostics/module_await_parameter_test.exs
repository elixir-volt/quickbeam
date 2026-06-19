defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleAwaitParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module await function parameter diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.FunctionDeclaration{}]},
            errors} =
             Parser.parse("function f(await) {}", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "expected binding identifier"))
  end
end
