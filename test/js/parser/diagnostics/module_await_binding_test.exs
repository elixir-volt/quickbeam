defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleAwaitBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module await binding name diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.VariableDeclaration{}]},
            errors} =
             Parser.parse("var await;", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "expected binding identifier"))
  end
end
