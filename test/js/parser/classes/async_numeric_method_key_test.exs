defmodule QuickBEAM.JS.Parser.Classes.AsyncNumericMethodKeyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible async numeric class method names" do
    source = """
    class C {
      async 0() { return 1; }
      static async *1.5() { yield 2; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [method, static_method]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             key: %AST.Literal{value: 0},
             value: %AST.FunctionExpression{async: true, generator: false}
           } = method

    assert %AST.MethodDefinition{
             key: %AST.Literal{value: 1.5},
             static: true,
             value: %AST.FunctionExpression{async: true, generator: true}
           } =
             static_method
  end
end
