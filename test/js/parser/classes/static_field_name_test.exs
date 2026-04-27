defmodule QuickBEAM.JS.Parser.Classes.StaticFieldNameTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "parses static as an instance field name" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ClassDeclaration{
                  body: [
                    %AST.FieldDefinition{
                      key: %AST.Identifier{name: "static"},
                      static: false,
                      value: nil
                    }
                  ]
                }
              ]
            }} = Parser.parse("class C { static; }")
  end

  test "parses assigned static as an instance field name" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.AssignmentExpression{
                    right: %AST.ClassExpression{
                      body: [
                        %AST.FieldDefinition{
                          key: %AST.Identifier{name: "static"},
                          static: false,
                          value: %AST.Literal{value: "foo"}
                        }
                      ]
                    }
                  }
                }
              ]
            }} = Parser.parse(~s|value = class { static = "foo"; };|)
  end
end
