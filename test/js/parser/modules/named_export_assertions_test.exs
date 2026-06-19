defmodule QuickBEAM.JS.Parser.Modules.NamedExportAssertionsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible named re-export assertions syntax" do
    source = ~S|export { name as alias } from "dep" assert { type: "json" };|

    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExportNamedDeclaration{
                  specifiers: [specifier],
                  source: %AST.Literal{value: "dep"},
                  attributes: attributes
                }
              ]
            }} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportSpecifier{
             local: %AST.Identifier{name: "name"},
             exported: %AST.Identifier{name: "alias"}
           } = specifier

    assert %AST.ObjectExpression{properties: [%AST.Property{key: %AST.Identifier{name: "type"}}]} =
             attributes
  end
end
