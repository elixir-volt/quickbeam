defmodule QuickBEAM.JS.Parser.Classes.AsyncStringMethodKeyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible async string class method names" do
    source = """
    class C {
      async "method-name"() { return 1; }
      static async "static-name"() { return 2; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [method, static_method]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             key: %AST.Literal{value: "method-name"},
             static: false,
             value: %AST.FunctionExpression{async: true}
           } = method

    assert %AST.MethodDefinition{
             key: %AST.Literal{value: "static-name"},
             static: true,
             value: %AST.FunctionExpression{async: true}
           } =
             static_method
  end
end
