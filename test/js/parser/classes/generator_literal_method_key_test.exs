defmodule QuickBEAM.JS.Parser.Classes.GeneratorLiteralMethodKeyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible generator literal class method names" do
    source = """
    class C {
      *"string-name"() { yield 1; }
      static *0() { yield 2; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [method, static_method]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             key: %AST.Literal{value: "string-name"},
             value: %AST.FunctionExpression{generator: true}
           } = method

    assert %AST.MethodDefinition{
             key: %AST.Literal{value: 0},
             static: true,
             value: %AST.FunctionExpression{generator: true}
           } = static_method
  end
end
