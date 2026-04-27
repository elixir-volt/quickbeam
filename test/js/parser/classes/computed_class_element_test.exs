defmodule QuickBEAM.JS.Parser.Classes.ComputedClassElementTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible computed class element syntax" do
    source = """
    class C {
      [method]() {}
      static [field] = 1;
      get [value]() { return 1; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [method, field, getter]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{key: %AST.Identifier{name: "method"}, computed: true} = method

    assert %AST.FieldDefinition{key: %AST.Identifier{name: "field"}, computed: true, static: true} =
             field

    assert %AST.MethodDefinition{key: %AST.Identifier{name: "value"}, computed: true, kind: :get} =
             getter
  end
end
