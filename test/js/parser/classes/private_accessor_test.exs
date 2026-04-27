defmodule QuickBEAM.JS.Parser.Classes.PrivateAccessorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible private accessor syntax" do
    source = """
    class C {
      #stored;
      get #value() { return 1; }
      set #value(value) { this.#stored = value; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [stored, getter, setter]}]}} =
             Parser.parse(source)

    assert %AST.FieldDefinition{key: %AST.PrivateIdentifier{name: "stored"}} = stored
    assert %AST.MethodDefinition{kind: :get, key: %AST.PrivateIdentifier{name: "value"}} = getter
    assert %AST.MethodDefinition{kind: :set, key: %AST.PrivateIdentifier{name: "value"}} = setter
  end
end
