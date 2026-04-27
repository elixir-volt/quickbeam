defmodule QuickBEAM.JS.Parser.Classes.MultipleStaticBlocksTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible multiple class static blocks" do
    source = """
    class C {
      static value = 0;
      static { this.value += 1; }
      method() { return this.value; }
      static { this.done = true; }
    }
    """

    assert {:ok,
            %AST.Program{
              body: [%AST.ClassDeclaration{body: [field, first_block, method, second_block]}]
            }} =
             Parser.parse(source)

    assert %AST.FieldDefinition{static: true, key: %AST.Identifier{name: "value"}} = field
    assert %AST.StaticBlock{body: [%AST.ExpressionStatement{}]} = first_block
    assert %AST.MethodDefinition{key: %AST.Identifier{name: "method"}} = method
    assert %AST.StaticBlock{body: [%AST.ExpressionStatement{}]} = second_block
  end
end
