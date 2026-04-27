defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleAwaitFunctionNameTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module await function name diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.FunctionDeclaration{}]},
            errors} =
             Parser.parse("function await() {}", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "expected binding identifier"))
  end
end
