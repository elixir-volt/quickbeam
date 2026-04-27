defmodule QuickBEAM.JS.Parser.Classes.ConstructorAccessorNotDuplicateTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible constructor plus constructor accessor syntax" do
    source = """
    class C {
      constructor() {}
      get constructor() { return 1; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [constructor, getter]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{kind: :constructor, key: %AST.Identifier{name: "constructor"}} =
             constructor

    assert %AST.MethodDefinition{kind: :get, key: %AST.Identifier{name: "constructor"}} = getter
  end
end
