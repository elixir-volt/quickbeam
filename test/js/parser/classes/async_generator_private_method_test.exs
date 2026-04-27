defmodule QuickBEAM.JS.Parser.Classes.AsyncGeneratorPrivateMethodTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible async generator private method syntax" do
    source = """
    class C {
      async *#method(value) { yield await value; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [method]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             key: %AST.PrivateIdentifier{name: "method"},
             value: %AST.FunctionExpression{async: true, generator: true}
           } = method
  end
end
