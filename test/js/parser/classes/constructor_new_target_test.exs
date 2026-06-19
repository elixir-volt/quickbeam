defmodule QuickBEAM.JS.Parser.Classes.ConstructorNewTargetTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible new.target in constructor syntax" do
    source = """
    class C {
      constructor() { this.target = new.target; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [constructor]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             kind: :constructor,
             value: %AST.FunctionExpression{
               body: %AST.BlockStatement{
                 body: [
                   %AST.ExpressionStatement{
                     expression: %AST.AssignmentExpression{
                       right: %AST.MetaProperty{
                         meta: %AST.Identifier{name: "new"},
                         property: %AST.Identifier{name: "target"}
                       }
                     }
                   }
                 ]
               }
             }
           } = constructor
  end
end
