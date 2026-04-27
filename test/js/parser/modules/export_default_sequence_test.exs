defmodule QuickBEAM.JS.Parser.Modules.ExportDefaultSequenceTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible default sequence export syntax" do
    source = "export default (setup(), value);"

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportDefaultDeclaration{
             declaration: %AST.SequenceExpression{
               expressions: [
                 %AST.CallExpression{callee: %AST.Identifier{name: "setup"}},
                 %AST.Identifier{name: "value"}
               ]
             }
           } = statement
  end
end
