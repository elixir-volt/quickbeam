defmodule QuickBEAM.JS.Parser.Classes.SuperConstructorCallTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible super constructor call syntax" do
    source = "class C extends B { constructor(value) { super(value); } }"

    assert {:ok,
            %AST.Program{
              body: [
                %AST.ClassDeclaration{
                  super_class: %AST.Identifier{name: "B"},
                  body: [constructor]
                }
              ]
            }} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             kind: :constructor,
             value: %AST.FunctionExpression{
               params: [%AST.Identifier{name: "value"}],
               body: %AST.BlockStatement{
                 body: [
                   %AST.ExpressionStatement{
                     expression: %AST.CallExpression{
                       callee: %AST.Identifier{name: "super"},
                       arguments: [%AST.Identifier{name: "value"}]
                     }
                   }
                 ]
               }
             }
           } = constructor
  end
end
