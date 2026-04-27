defmodule QuickBEAM.JS.Parser.Classes.NumericMethodKeyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible numeric class method names" do
    source = """
    class C {
      0() { return 0; }
      1.5() { return 1.5; }
      static 0x10() { return 16; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [zero, decimal, hex]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{key: %AST.Literal{value: 0}, static: false} = zero
    assert %AST.MethodDefinition{key: %AST.Literal{value: 1.5}, static: false} = decimal
    assert %AST.MethodDefinition{key: %AST.Literal{value: 16}, static: true} = hex
  end
end
