defmodule QuickBEAM.JS.Parser.Diagnostics.SloppyFutureReservedBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports Test262 sloppy let and static var bindings" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{
                  declarations: [%AST.VariableDeclarator{id: %AST.Identifier{name: "let"}}]
                },
                %AST.VariableDeclaration{
                  declarations: [%AST.VariableDeclarator{id: %AST.Identifier{name: "static"}}]
                }
              ]
            }} = Parser.parse("var let = 1; var static = 2;")
  end
end
