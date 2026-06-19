defmodule QuickBEAM.JS.Parser.Classes.PrivateUnicodeIdentifierTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible private unicode escape identifier syntax" do
    source = """
    class C {
      #\\u0061 = 1;
      m() { return this.#\\u0061; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [field, method]}]}} =
             Parser.parse(source)

    assert %AST.FieldDefinition{key: %AST.PrivateIdentifier{name: "a"}} = field

    assert %AST.MethodDefinition{
             value: %AST.FunctionExpression{
               body: %AST.BlockStatement{
                 body: [
                   %AST.ReturnStatement{
                     argument: %AST.MemberExpression{property: %AST.PrivateIdentifier{name: "a"}}
                   }
                 ]
               }
             }
           } = method
  end
end
