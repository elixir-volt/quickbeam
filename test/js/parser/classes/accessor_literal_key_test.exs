defmodule QuickBEAM.JS.Parser.Classes.AccessorLiteralKeyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible class accessor literal keys" do
    source = """
    class C {
      get "value-name"() { return 1; }
      static set 0(value) { this.value = value; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [getter, setter]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             key: %AST.Literal{value: "value-name"},
             kind: :get,
             static: false
           } = getter

    assert %AST.MethodDefinition{key: %AST.Literal{value: 0}, kind: :set, static: true} = setter
  end
end
