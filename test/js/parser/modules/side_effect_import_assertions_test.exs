defmodule QuickBEAM.JS.Parser.Modules.SideEffectImportAssertionsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible side-effect import assertions syntax" do
    source = ~S|import "dep" assert { type: "json" };|

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

    assert %AST.ObjectExpression{properties: [%AST.Property{key: %AST.Identifier{name: "type"}}]} =
             attributes
  end
end
