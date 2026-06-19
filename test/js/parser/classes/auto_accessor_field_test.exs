defmodule QuickBEAM.JS.Parser.Classes.AutoAccessorFieldTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "parses public auto-accessor field syntax" do
    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: elements}]}} =
             Parser.parse("class C { accessor x; accessor 'y' = 1; accessor [name] = 2; }")

    assert [
             %AST.FieldDefinition{key: %AST.Identifier{name: "x"}, value: nil},
             %AST.FieldDefinition{key: %AST.Literal{value: "y"}, value: %AST.Literal{value: 1}},
             %AST.FieldDefinition{key: %AST.Identifier{name: "name"}, computed: true}
           ] = elements
  end

  test "parses private auto-accessor field syntax" do
    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [field]}]}} =
             Parser.parse("class C { accessor #x = 1; }")

    assert %AST.FieldDefinition{
             key: %AST.PrivateIdentifier{name: "x"},
             value: %AST.Literal{value: 1}
           } =
             field
  end

  test "keeps accessor as a normal field name when it has no auto-accessor key" do
    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [field]}]}} =
             Parser.parse("class C { accessor = 1; }")

    assert %AST.FieldDefinition{
             key: %AST.Identifier{name: "accessor"},
             value: %AST.Literal{value: 1}
           } =
             field
  end
end
