defmodule QuickBEAM.JS.Parser.Modules.ExportAllAliasAssertionsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible export-all alias assertions syntax" do
    source = ~S|export * as namespace from "dep" assert { type: "json" };|

    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExportAllDeclaration{
                  exported: %AST.Identifier{name: "namespace"},
                  source: %AST.Literal{value: "dep"},
                  attributes: attributes
                }
              ]
            }} =
             Parser.parse(source, source_type: :module)

    assert %AST.ObjectExpression{properties: [%AST.Property{key: %AST.Identifier{name: "type"}}]} =
             attributes
  end
end
