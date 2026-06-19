defmodule QuickBEAM.JS.Parser.Classes.ConstructorSuperCallTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible constructor super call syntax" do
    source = """
    class D extends C {
      constructor(value) { super(value); this.value = value; }
    }
    """

    assert {:ok,
            %AST.Program{
              body: [
                %AST.ClassDeclaration{
                  super_class: %AST.Identifier{name: "C"},
                  body: [constructor]
                }
              ]
            }} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             kind: :constructor,
             key: %AST.Identifier{name: "constructor"},
             value: %AST.FunctionExpression{
               params: [%AST.Identifier{name: "value"}],
               body: %AST.BlockStatement{
                 body: [
                   %AST.ExpressionStatement{
                     expression: %AST.CallExpression{callee: %AST.Identifier{name: "super"}}
                   },
                   %AST.ExpressionStatement{
                     expression: %AST.AssignmentExpression{
                       left: %AST.MemberExpression{object: %AST.Identifier{name: "this"}}
                     }
                   }
                 ]
               }
             }
           } = constructor
  end
end
