defmodule QuickBEAM.JS.Parser.Modules.DefaultSpecifierImportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible default named import specifier syntax" do
    assert {:ok, %AST.Program{body: [statement]}} =
             Parser.parse(~s|import { default as foo } from "dep";|, source_type: :module)

    assert %AST.ImportDeclaration{
             specifiers: [
               %AST.ImportSpecifier{
                 imported: %AST.Identifier{name: "default"},
                 local: %AST.Identifier{name: "foo"}
               }
             ],
             source: %AST.Literal{value: "dep"}
           } = statement
  end
end
