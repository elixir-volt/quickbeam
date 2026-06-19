defmodule QuickBEAM.JS.Parser.Modules.NamedImportAttributesTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible named import attributes syntax" do
    source = ~S(import { value as localValue } from "./data.json" assert { type: "json" };)

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ImportDeclaration{
             specifiers: [
               %AST.ImportSpecifier{
                 imported: %AST.Identifier{name: "value"},
                 local: %AST.Identifier{name: "localValue"}
               }
             ],
             source: %AST.Literal{value: "./data.json"},
             attributes: %AST.ObjectExpression{
               properties: [%AST.Property{key: %AST.Identifier{name: "type"}}]
             }
           } = statement
  end
end
