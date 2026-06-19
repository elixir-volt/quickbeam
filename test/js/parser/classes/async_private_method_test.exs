defmodule QuickBEAM.JS.Parser.Classes.AsyncPrivateMethodTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible async private method syntax" do
    source = """
    class C {
      async #method(value) { return await value; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [method]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             key: %AST.PrivateIdentifier{name: "method"},
             value: %AST.FunctionExpression{async: true}
           } = method
  end
end
