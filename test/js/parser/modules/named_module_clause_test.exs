defmodule QuickBEAM.JS.Parser.Modules.NamedModuleClauseTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible default-only named import and local export syntax" do
    source = """
    import defaultExport from "mod";
    import { foo } from "mod";
    export { foo };
    """

    assert {:ok, %AST.Program{body: [default_import, named_import, local_export]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ImportDeclaration{
             specifiers: [
               %AST.ImportDefaultSpecifier{local: %AST.Identifier{name: "defaultExport"}}
             ],
             source: %AST.Literal{value: "mod"}
           } = default_import

    assert %AST.ImportDeclaration{
             specifiers: [%AST.ImportSpecifier{imported: %AST.Identifier{name: "foo"}}],
             source: %AST.Literal{value: "mod"}
           } = named_import

    assert %AST.ExportNamedDeclaration{
             specifiers: [%AST.ExportSpecifier{local: %AST.Identifier{name: "foo"}}],
             source: nil
           } = local_export
  end
end
