defmodule QuickBEAM.JS.Parser.Modules.NamespaceImportAttributesTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible namespace import attributes syntax" do
    source = ~S(import * as data from "./data.json" with { type: "json" };)

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ImportDeclaration{
             specifiers: [%AST.ImportNamespaceSpecifier{local: %AST.Identifier{name: "data"}}],
             source: %AST.Literal{value: "./data.json"},
             attributes: %AST.ObjectExpression{
               properties: [%AST.Property{key: %AST.Identifier{name: "type"}}]
             }
           } = statement
  end
end
