defmodule QuickBEAM.JS.Parser.Modules.StringNamespaceExportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible string namespace re-export syntax" do
    source = ~S(export * as "external-name" from "dep";)

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportAllDeclaration{
             exported: %AST.Literal{value: "external-name"},
             source: %AST.Literal{value: "dep"}
           } = statement
  end
end
