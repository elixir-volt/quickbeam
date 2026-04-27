defmodule QuickBEAM.JS.Parser.Classes.ReservedMemberNamesTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible reserved class member names" do
    source = "class C { default() {} class = 1; static import() {} }"

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: members}]}} =
             Parser.parse(source)

    assert [
             %AST.MethodDefinition{
               key: %AST.Identifier{name: "default"},
               kind: :method,
               static: false
             },
             %AST.FieldDefinition{
               key: %AST.Identifier{name: "class"},
               value: %AST.Literal{value: 1},
               static: false
             },
             %AST.MethodDefinition{
               key: %AST.Identifier{name: "import"},
               kind: :method,
               static: true
             }
           ] = members
  end
end
