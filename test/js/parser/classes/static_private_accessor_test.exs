defmodule QuickBEAM.JS.Parser.Classes.StaticPrivateAccessorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible static private accessor syntax" do
    source = """
    class C {
      static #stored;
      static get #value() { return 1; }
      static set #value(value) { this.#stored = value; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [stored, getter, setter]}]}} =
             Parser.parse(source)

    assert %AST.FieldDefinition{static: true, key: %AST.PrivateIdentifier{name: "stored"}} =
             stored

    assert %AST.MethodDefinition{
             kind: :get,
             static: true,
             key: %AST.PrivateIdentifier{name: "value"}
           } = getter

    assert %AST.MethodDefinition{
             kind: :set,
             static: true,
             key: %AST.PrivateIdentifier{name: "value"}
           } = setter
  end
end
