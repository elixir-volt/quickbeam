defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleDestructuringBindingNameTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module object destructuring eval binding diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.VariableDeclaration{}]},
            errors} =
             Parser.parse("var { eval } = object;", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
