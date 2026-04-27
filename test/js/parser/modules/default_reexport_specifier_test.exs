defmodule QuickBEAM.JS.Parser.Modules.DefaultReexportSpecifierTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible default re-export specifier syntax" do
    source = ~S(export { default as namedDefault } from "dep";)

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportNamedDeclaration{
             specifiers: [
               %AST.ExportSpecifier{
                 local: %AST.Identifier{name: "default"},
                 exported: %AST.Identifier{name: "namedDefault"}
               }
             ],
             source: %AST.Literal{value: "dep"}
           } = statement
  end
end
