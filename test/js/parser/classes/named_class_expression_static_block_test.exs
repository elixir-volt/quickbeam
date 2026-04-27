defmodule QuickBEAM.JS.Parser.Classes.NamedClassExpressionStaticBlockTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible named class expression static block syntax" do
    source = "value = class Named { static { this.value = 1; } };"

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ClassExpression{
                 id: %AST.Identifier{name: "Named"},
                 body: [
                   %AST.StaticBlock{
                     body: [%AST.ExpressionStatement{expression: %AST.AssignmentExpression{}}]
                   }
                 ]
               }
             }
           } = statement
  end
end
