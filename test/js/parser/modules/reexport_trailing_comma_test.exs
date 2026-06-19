defmodule QuickBEAM.JS.Parser.Modules.ReexportTrailingCommaTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible named re-export trailing comma syntax" do
    source = ~S(export { value, other as aliasValue, } from "dep";)

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportNamedDeclaration{
             specifiers: [
               %AST.ExportSpecifier{local: %AST.Identifier{name: "value"}},
               %AST.ExportSpecifier{
                 local: %AST.Identifier{name: "other"},
                 exported: %AST.Identifier{name: "aliasValue"}
               }
             ],
             source: %AST.Literal{value: "dep"}
           } = statement
  end
end
