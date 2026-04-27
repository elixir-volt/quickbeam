defmodule QuickBEAM.JS.Parser.Classes.StaticConstructorNotDuplicateTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible static constructor plus constructor syntax" do
    source = """
    class C {
      constructor() {}
      static constructor() {}
    }
    """

    assert {:ok,
            %AST.Program{body: [%AST.ClassDeclaration{body: [constructor, static_constructor]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             kind: :constructor,
             static: false,
             key: %AST.Identifier{name: "constructor"}
           } = constructor

    assert %AST.MethodDefinition{
             kind: :method,
             static: true,
             key: %AST.Identifier{name: "constructor"}
           } = static_constructor
  end
end
