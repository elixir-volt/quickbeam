defmodule QuickBEAM.JS.Parser.Classes.PrivateMethodTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible private method syntax" do
    source = """
    class C {
      #method(value) { return value; }
      call(value) { return this.#method(value); }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [private_method, call_method]}]}} =
             Parser.parse(source)

    assert %AST.MethodDefinition{key: %AST.PrivateIdentifier{name: "method"}} = private_method

    assert %AST.MethodDefinition{
             value: %AST.FunctionExpression{
               body: %AST.BlockStatement{
                 body: [
                   %AST.ReturnStatement{
                     argument: %AST.CallExpression{
                       callee: %AST.MemberExpression{
                         property: %AST.PrivateIdentifier{name: "method"}
                       }
                     }
                   }
                 ]
               }
             }
           } = call_method
  end
end
