defmodule QuickBEAM.JS.Parser.Classes.StringMethodKeyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible string class method names" do
    source = """
    class C {
      "method-name"() { return 1; }
      static "static-name"() { return 2; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [method, static_method]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{key: %AST.Literal{value: "method-name"}, static: false} = method

    assert %AST.MethodDefinition{key: %AST.Literal{value: "static-name"}, static: true} =
             static_method
  end
end
