defmodule QuickBEAM.JS.Parser.Modules.NamedExportTrailingCommaTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible named export trailing comma syntax" do
    source = ~S(export { value, other as aliasValue, };)

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportNamedDeclaration{
             specifiers: [
               %AST.ExportSpecifier{
                 local: %AST.Identifier{name: "value"},
                 exported: %AST.Identifier{name: "value"}
               },
               %AST.ExportSpecifier{
                 local: %AST.Identifier{name: "other"},
                 exported: %AST.Identifier{name: "aliasValue"}
               }
             ],
             source: nil
           } = statement
  end
end
