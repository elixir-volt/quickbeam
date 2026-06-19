defmodule QuickBEAM.JS.Parser.Modules.ExportAttributesTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible re-export attributes syntax" do
    source = """
    export { value } from "./data.json" with { type: "json" };
    export * from "./all.json" assert { type: "json" };
    """

    assert {:ok, %AST.Program{source_type: :module, body: [named, all]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportNamedDeclaration{
             specifiers: [%AST.ExportSpecifier{local: %AST.Identifier{name: "value"}}],
             source: %AST.Literal{value: "./data.json"},
             attributes: %AST.ObjectExpression{
               properties: [%AST.Property{key: %AST.Identifier{name: "type"}}]
             }
           } = named

    assert %AST.ExportAllDeclaration{
             source: %AST.Literal{value: "./all.json"},
             attributes: %AST.ObjectExpression{
               properties: [%AST.Property{value: %AST.Literal{value: "json"}}]
             }
           } = all
  end
end
