defmodule QuickBEAM.JS.Parser.Modules.StringNameImportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible string import name syntax" do
    source = ~S(import { "external-name" as localName } from "dep";)

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ImportDeclaration{
             specifiers: [
               %AST.ImportSpecifier{
                 imported: %AST.Literal{value: "external-name"},
                 local: %AST.Identifier{name: "localName"}
               }
             ],
             source: %AST.Literal{value: "dep"}
           } = statement
  end
end
