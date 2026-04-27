defmodule QuickBEAM.JS.Parser.Classes.ConstructorFieldTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible class field named constructor" do
    source = """
    class C {
      constructor = 1;
      static constructor = 2;
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [field, static_field]}]}} =
             Parser.parse(source)

    assert %AST.FieldDefinition{
             key: %AST.Identifier{name: "constructor"},
             value: %AST.Literal{value: 1},
             static: false
           } = field

    assert %AST.FieldDefinition{
             key: %AST.Identifier{name: "constructor"},
             value: %AST.Literal{value: 2},
             static: true
           } = static_field
  end
end
