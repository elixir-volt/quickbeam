defmodule QuickBEAM.JS.Parser.Core.UnicodeEscapeIdentifierTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible unicode escape identifier syntax" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("var abc\\u0064 = 1;")

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{
                 id: %AST.Identifier{name: "abcd"},
                 init: %AST.Literal{value: 1}
               }
             ]
           } = statement
  end
end
