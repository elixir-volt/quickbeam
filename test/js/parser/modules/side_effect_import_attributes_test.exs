defmodule QuickBEAM.JS.Parser.Modules.SideEffectImportAttributesTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible side-effect import attributes syntax" do
    source = ~S|import "dep" with { type: "json" };|

    assert {:ok,
            %AST.Program{
              body: [
                %AST.ImportDeclaration{
                  specifiers: [],
                  source: %AST.Literal{value: "dep"},
                  attributes: attributes
                }
              ]
            }} =
             Parser.parse(source, source_type: :module)

    assert %AST.ObjectExpression{
             properties: [
               %AST.Property{
                 key: %AST.Identifier{name: "type"},
                 value: %AST.Literal{value: "json"}
               }
             ]
           } = attributes
  end
end
