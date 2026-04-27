defmodule QuickBEAM.JS.Parser.Classes.PrivateInExpressionTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible private-in expression syntax" do
    source = """
    class C {
      #x;
      has(object) { return #x in object; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [_field, method]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             value: %AST.FunctionExpression{
               body: %AST.BlockStatement{
                 body: [
                   %AST.ReturnStatement{
                     argument: %AST.BinaryExpression{
                       operator: "in",
                       left: %AST.PrivateIdentifier{name: "x"},
                       right: %AST.Identifier{name: "object"}
                     }
                   }
                 ]
               }
             }
           } = method
  end
end
