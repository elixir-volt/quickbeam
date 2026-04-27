defmodule QuickBEAM.JS.Parser.Classes.StaticConstructorMethodTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible static constructor method syntax" do
    source = """
    class C {
      static constructor() { return 1; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [method]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             kind: :method,
             static: true,
             key: %AST.Identifier{name: "constructor"},
             value: %AST.FunctionExpression{params: []}
           } = method
  end
end
