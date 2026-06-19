defmodule QuickBEAM.JS.Parser.Classes.SuperAssignmentTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible super property assignment syntax" do
    source = """
    class D extends C {
      set(value) { super.value = value; super["other"] = value; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [method]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             value: %AST.FunctionExpression{
               body: %AST.BlockStatement{
                 body: [
                   %AST.ExpressionStatement{
                     expression: %AST.AssignmentExpression{
                       left: %AST.MemberExpression{
                         object: %AST.Identifier{name: "super"},
                         computed: false
                       }
                     }
                   },
                   %AST.ExpressionStatement{
                     expression: %AST.AssignmentExpression{
                       left: %AST.MemberExpression{
                         object: %AST.Identifier{name: "super"},
                         computed: true
                       }
                     }
                   }
                 ]
               }
             }
           } = method
  end
end
