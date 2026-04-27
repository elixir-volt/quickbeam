defmodule QuickBEAM.JS.Parser.Classes.BooleanPropertyNameTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "parses boolean literal names after dot property access" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.MemberExpression{
                    property: %AST.Identifier{name: "false"}
                  }
                }
              ]
            }} = Parser.parse("C.prototype.false;")
  end

  test "parses computed accessor names using in expressions" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ClassDeclaration{
                  body: [
                    %AST.MethodDefinition{
                      kind: :get,
                      key: %AST.BinaryExpression{operator: "in"}
                    }
                  ]
                }
              ]
            }} = Parser.parse(~s|class C { get ["x" in empty]() { return value; } }|)
  end
end
