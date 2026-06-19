defmodule QuickBEAM.JS.Parser.Modules.ImportAttributesTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible static import attributes syntax" do
    source = ~S(import data from "./data.json" with { type: "json" };)

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ImportDeclaration{
             specifiers: [%AST.ImportDefaultSpecifier{local: %AST.Identifier{name: "data"}}],
             source: %AST.Literal{value: "./data.json"},
             attributes: %AST.ObjectExpression{
               properties: [
                 %AST.Property{
                   key: %AST.Identifier{name: "type"},
                   value: %AST.Literal{value: "json"}
                 }
               ]
             }
           } = statement
  end

  test "ports QuickJS-compatible side-effect import assertion syntax" do
    source = ~S(import "./setup.json" assert { type: "json" };)

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ImportDeclaration{
             specifiers: [],
             source: %AST.Literal{value: "./setup.json"},
             attributes: %AST.ObjectExpression{}
           } = statement
  end
end
