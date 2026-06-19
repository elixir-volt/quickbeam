defmodule QuickBEAM.JS.Parser.Modules.DefaultNamespaceImportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible default plus namespace import syntax" do
    source = ~S(import defaultValue, * as namespaceValue from "dep";)

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ImportDeclaration{
             specifiers: [
               %AST.ImportDefaultSpecifier{local: %AST.Identifier{name: "defaultValue"}},
               %AST.ImportNamespaceSpecifier{local: %AST.Identifier{name: "namespaceValue"}}
             ],
             source: %AST.Literal{value: "dep"}
           } = statement
  end
end
