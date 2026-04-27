defmodule QuickBEAM.JS.Parser.Classes.SuperMemberAccessTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible super member access syntax" do
    source = "class C extends B { method() { return super.value; } }"

    assert {:ok,
            %AST.Program{
              body: [
                %AST.ClassDeclaration{super_class: %AST.Identifier{name: "B"}, body: [method]}
              ]
            }} =
             Parser.parse(source)

    assert %AST.MethodDefinition{
             value: %AST.FunctionExpression{
               body: %AST.BlockStatement{
                 body: [
                   %AST.ReturnStatement{
                     argument: %AST.MemberExpression{
                       object: %AST.Identifier{name: "super"},
                       property: %AST.Identifier{name: "value"}
                     }
                   }
                 ]
               }
             }
           } = method
  end
end
