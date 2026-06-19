defmodule QuickBEAM.JS.Parser.Diagnostics.DuplicateConstructorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS duplicate class constructor diagnostics" do
    source = """
    class C {
      constructor() {}
      constructor(value) { this.value = value; }
    }
    """

    assert {:error,
            %AST.Program{
              body: [
                %AST.ClassDeclaration{body: [%AST.MethodDefinition{}, %AST.MethodDefinition{}]}
              ]
            }, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "duplicate constructor"))
  end
end
