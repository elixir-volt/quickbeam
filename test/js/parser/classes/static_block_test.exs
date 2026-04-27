defmodule QuickBEAM.JS.Parser.Classes.StaticBlockTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible class static block syntax" do
    source = """
    class C {
      static {
        this.value = 1;
      }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [static_block]}]}} =
             Parser.parse(source)

    assert %AST.StaticBlock{
             body: [
               %AST.ExpressionStatement{
                 expression: %AST.AssignmentExpression{
                   left: %AST.MemberExpression{
                     object: %AST.Identifier{name: "this"},
                     property: %AST.Identifier{name: "value"}
                   },
                   right: %AST.Literal{value: 1}
                 }
               }
             ]
           } = static_block
  end
end
