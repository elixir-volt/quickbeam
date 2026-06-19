defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleStrictBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module eval binding strict diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.VariableDeclaration{}]},
            errors} =
             Parser.parse("var eval;", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end

  test "ports QuickJS module arguments function binding strict diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.FunctionDeclaration{}]},
            errors} =
             Parser.parse("function arguments() {}", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
