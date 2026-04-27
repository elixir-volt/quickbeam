defmodule QuickBEAM.JS.Parser.Modules.DefaultSpecifierExportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible default specifier re-export syntax" do
    source = """
    export { default as foo } from "dep";
    export { foo as default };
    """

    assert {:ok, %AST.Program{body: [reexport_default, export_as_default]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportNamedDeclaration{
             specifiers: [
               %AST.ExportSpecifier{
                 local: %AST.Identifier{name: "default"},
                 exported: %AST.Identifier{name: "foo"}
               }
             ],
             source: %AST.Literal{value: "dep"}
           } = reexport_default

    assert %AST.ExportNamedDeclaration{
             specifiers: [
               %AST.ExportSpecifier{
                 local: %AST.Identifier{name: "foo"},
                 exported: %AST.Identifier{name: "default"}
               }
             ],
             source: nil
           } = export_as_default
  end
end
