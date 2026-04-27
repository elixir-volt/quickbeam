defmodule QuickBEAM.JS.Parser.Classes.NonConstructorMethodNamesTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible non-constructor methods named constructor" do
    source = """
    class C {
      *constructor() { yield 1; }
      async constructor() { return 2; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [generator, async_method]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             kind: :method,
             key: %AST.Identifier{name: "constructor"},
             value: %AST.FunctionExpression{generator: true}
           } = generator

    assert %AST.MethodDefinition{
             kind: :method,
             key: %AST.Identifier{name: "constructor"},
             value: %AST.FunctionExpression{async: true}
           } = async_method
  end
end
