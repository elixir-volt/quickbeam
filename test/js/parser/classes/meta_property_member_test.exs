defmodule QuickBEAM.JS.Parser.Classes.MetaPropertyMemberTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible meta properties in class members" do
    source = "class C { field = new.target; method() { return import.meta.url; } }"

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [field, method]}]}} =
             Parser.parse(source)

    assert %AST.FieldDefinition{
             value: %AST.MetaProperty{
               meta: %AST.Identifier{name: "new"},
               property: %AST.Identifier{name: "target"}
             }
           } = field

    assert %AST.MethodDefinition{
             value: %AST.FunctionExpression{
               body: %AST.BlockStatement{
                 body: [
                   %AST.ReturnStatement{
                     argument: %AST.MemberExpression{
                       object: %AST.MetaProperty{meta: %AST.Identifier{name: "import"}}
                     }
                   }
                 ]
               }
             }
           } = method
  end
end
