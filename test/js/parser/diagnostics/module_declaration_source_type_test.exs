defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleDeclarationSourceTypeTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS import declaration script source diagnostics" do
    assert {:error, %AST.Program{source_type: :script, body: [%AST.ImportDeclaration{}]}, errors} =
             Parser.parse(~S|import value from "dep";|)

    assert Enum.any?(
             errors,
             &(&1.message == "import/export declarations only allowed in modules")
           )
  end

  test "ports QuickJS export declaration script source diagnostics" do
    assert {:error, %AST.Program{source_type: :script, body: [%AST.ExportNamedDeclaration{}]},
            errors} =
             Parser.parse("export var value = 1;")

    assert Enum.any?(
             errors,
             &(&1.message == "import/export declarations only allowed in modules")
           )
  end
end
