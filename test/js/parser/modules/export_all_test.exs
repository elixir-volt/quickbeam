defmodule QuickBEAM.JS.Parser.Modules.ExportAllTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible export-all module syntax" do
    source = ~s|export * from "dep"; export * as ns from "dep2";|

    assert {:ok, %AST.Program{body: [all_export, namespace_export]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportAllDeclaration{exported: nil, source: %AST.Literal{value: "dep"}} =
             all_export

    assert %AST.ExportAllDeclaration{
             exported: %AST.Identifier{name: "ns"},
             source: %AST.Literal{value: "dep2"}
           } = namespace_export
  end
end
