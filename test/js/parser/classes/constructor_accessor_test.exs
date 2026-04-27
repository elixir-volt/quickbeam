defmodule QuickBEAM.JS.Parser.Classes.ConstructorAccessorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible class accessor named constructor" do
    source = """
    class C {
      get constructor() { return 1; }
      set constructor(value) { this.value = value; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [getter, setter]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             kind: :get,
             key: %AST.Identifier{name: "constructor"},
             static: false
           } = getter

    assert %AST.MethodDefinition{
             kind: :set,
             key: %AST.Identifier{name: "constructor"},
             static: false
           } = setter
  end
end
