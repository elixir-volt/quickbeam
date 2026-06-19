defmodule QuickBEAM.JS.Parser.Classes.LiteralFieldKeyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible literal class field names" do
    source = """
    class C {
      "field-name" = 1;
      static 0 = 2;
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [field, static_field]}]}} =
             Parser.parse(source)

    assert %AST.FieldDefinition{
             key: %AST.Literal{value: "field-name"},
             value: %AST.Literal{value: 1},
             static: false
           } = field

    assert %AST.FieldDefinition{
             key: %AST.Literal{value: 0},
             value: %AST.Literal{value: 2},
             static: true
           } = static_field
  end
end
