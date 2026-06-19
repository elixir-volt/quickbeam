defmodule QuickBEAM.JS.Parser.Core.BracedUnicodeEscapeIdentifierTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible braced unicode escape identifier syntax" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("var smile\\u{79} = 1;")

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{
                 id: %AST.Identifier{name: "smiley"},
                 init: %AST.Literal{value: 1}
               }
             ]
           } = statement
  end
end
