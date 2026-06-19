defmodule QuickBEAM.JS.Parser.Modules.DefaultImportSpecifierTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible default named import specifier syntax" do
    source = ~S(import { default as namedDefault } from "dep";)

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ImportDeclaration{
             specifiers: [
               %AST.ImportSpecifier{
                 imported: %AST.Identifier{name: "default"},
                 local: %AST.Identifier{name: "namedDefault"}
               }
             ],
             source: %AST.Literal{value: "dep"}
           } = statement
  end
end
