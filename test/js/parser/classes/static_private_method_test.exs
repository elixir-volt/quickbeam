defmodule QuickBEAM.JS.Parser.Classes.StaticPrivateMethodTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible static private method syntax" do
    source = """
    class C {
      static #method(value) { return value; }
      static call(value) { return this.#method(value); }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [private_method, call_method]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{static: true, key: %AST.PrivateIdentifier{name: "method"}} =
             private_method

    assert %AST.MethodDefinition{static: true, key: %AST.Identifier{name: "call"}} = call_method
  end
end
