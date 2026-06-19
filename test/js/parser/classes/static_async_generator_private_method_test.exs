defmodule QuickBEAM.JS.Parser.Classes.StaticAsyncGeneratorPrivateMethodTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible static async generator private method syntax" do
    source = """
    class C {
      static async *#method(value) { yield await value; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [method]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             static: true,
             key: %AST.PrivateIdentifier{name: "method"},
             value: %AST.FunctionExpression{async: true, generator: true}
           } = method
  end
end
