defmodule QuickBEAM.JS.Parser.Classes.ClassStaticThisFieldTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS static class field this-member syntax" do
    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [field]}]}} =
             Parser.parse("class S { static z = this.x; }")

    assert %AST.FieldDefinition{
             static: true,
             key: %AST.Identifier{name: "z"},
             value: %AST.MemberExpression{
               object: %AST.Identifier{name: "this"},
               property: %AST.Identifier{name: "x"}
             }
           } = field
  end
end
