defmodule QuickBEAM.JS.Parser.Functions.NewTargetTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible new.target meta-property syntax" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{body: %AST.BlockStatement{body: [return_statement]}}
              ]
            }} =
             Parser.parse("function f() { return new.target; }")

    assert %AST.ReturnStatement{
             argument: %AST.MetaProperty{
               meta: %AST.Identifier{name: "new"},
               property: %AST.Identifier{name: "target"}
             }
           } = return_statement
  end
end
