defmodule QuickBEAM.JS.Parser.Modules.DefaultNamespaceExportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible default namespace re-export syntax" do
    source = ~S(export * as default from "dep";)

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportAllDeclaration{
             exported: %AST.Identifier{name: "default"},
             source: %AST.Literal{value: "dep"}
           } = statement
  end
end
