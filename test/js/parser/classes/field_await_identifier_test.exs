defmodule QuickBEAM.JS.Parser.Classes.FieldAwaitIdentifierTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports await identifier in class field inside async function script code" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{},
                %AST.FunctionDeclaration{
                  async: true,
                  body: %AST.BlockStatement{
                    body: [
                      %AST.ReturnStatement{
                        argument: %AST.ClassExpression{
                          body: [
                            %AST.FieldDefinition{
                              value: %AST.Identifier{name: "await"}
                            }
                          ]
                        }
                      }
                    ]
                  }
                }
              ]
            }} =
             Parser.parse(
               "var await = 1; async function getClass() { return class { x = await; }; }"
             )
  end
end
