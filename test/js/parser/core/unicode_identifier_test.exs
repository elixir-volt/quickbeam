defmodule QuickBEAM.JS.Parser.Core.UnicodeIdentifierTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible unicode identifier syntax" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("var ȣ = 1;")

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{
                 id: %AST.Identifier{name: "ȣ"},
                 init: %AST.Literal{value: 1}
               }
             ]
           } = statement
  end
end
