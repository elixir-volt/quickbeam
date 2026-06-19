defmodule QuickBEAM.JS.Parser.Modules.NamedImportTrailingCommaTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible named import trailing comma syntax" do
    source = ~S(import { value, other as aliasValue, } from "dep";)

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ImportDeclaration{
             specifiers: [
               %AST.ImportSpecifier{
                 imported: %AST.Identifier{name: "value"},
                 local: %AST.Identifier{name: "value"}
               },
               %AST.ImportSpecifier{
                 imported: %AST.Identifier{name: "other"},
                 local: %AST.Identifier{name: "aliasValue"}
               }
             ],
             source: %AST.Literal{value: "dep"}
           } = statement
  end
end
