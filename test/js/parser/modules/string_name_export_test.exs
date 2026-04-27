defmodule QuickBEAM.JS.Parser.Modules.StringNameExportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible string export name syntax" do
    source = """
    export { value as "external-name" };
    export { "external-name" as value } from "dep";
    """

    assert {:ok, %AST.Program{body: [local_export, reexport]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportNamedDeclaration{
             specifiers: [
               %AST.ExportSpecifier{
                 local: %AST.Identifier{name: "value"},
                 exported: %AST.Literal{value: "external-name"}
               }
             ],
             source: nil
           } = local_export

    assert %AST.ExportNamedDeclaration{
             specifiers: [
               %AST.ExportSpecifier{
                 local: %AST.Literal{value: "external-name"},
                 exported: %AST.Identifier{name: "value"}
               }
             ],
             source: %AST.Literal{value: "dep"}
           } = reexport
  end
end
