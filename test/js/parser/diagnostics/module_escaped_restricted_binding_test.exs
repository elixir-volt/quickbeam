defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleEscapedRestrictedBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module escaped await binding diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.VariableDeclaration{}]},
            errors} =
             Parser.parse(~S|var aw\u0061it;|, source_type: :module)

    assert Enum.any?(errors, &(&1.message == "expected binding identifier"))
  end

  test "ports QuickJS module escaped eval binding diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.VariableDeclaration{}]},
            errors} =
             Parser.parse(~S|var ev\u0061l;|, source_type: :module)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
