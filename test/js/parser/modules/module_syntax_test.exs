defmodule QuickBEAM.JS.Parser.Modules.ModuleSyntaxTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible import and export module syntax" do
    source = """
    import "side-effect";
    import defaultExport, { foo as bar, baz } from "mod";
    import * as ns from "mod2";
    export { bar as foo, baz } from "mod";
    export const answer = 42;
    export function f() { return answer; }
    export class C {}
    """

    assert {:ok,
            %AST.Program{
              body: [
                side_effect,
                named_import,
                namespace_import,
                named_export,
                const_export,
                function_export,
                class_export
              ]
            }} =
             Parser.parse(source, source_type: :module)

    assert %AST.ImportDeclaration{source: %AST.Literal{value: "side-effect"}, specifiers: []} =
             side_effect

    assert %AST.ImportDeclaration{
             specifiers: [
               %AST.ImportDefaultSpecifier{},
               %AST.ImportSpecifier{},
               %AST.ImportSpecifier{}
             ]
           } = named_import

    assert %AST.ImportDeclaration{
             specifiers: [%AST.ImportNamespaceSpecifier{local: %AST.Identifier{name: "ns"}}]
           } = namespace_import

    assert %AST.ExportNamedDeclaration{
             specifiers: [%AST.ExportSpecifier{}, %AST.ExportSpecifier{}],
             source: %AST.Literal{value: "mod"}
           } = named_export

    assert %AST.ExportNamedDeclaration{declaration: %AST.VariableDeclaration{kind: :const}} =
             const_export

    assert %AST.ExportNamedDeclaration{
             declaration: %AST.FunctionDeclaration{id: %AST.Identifier{name: "f"}}
           } = function_export

    assert %AST.ExportNamedDeclaration{
             declaration: %AST.ClassDeclaration{id: %AST.Identifier{name: "C"}}
           } = class_export
  end
end
