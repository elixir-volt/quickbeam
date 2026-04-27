defmodule QuickBEAM.JS.Parser.Modules.DefaultAwaitExportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible default await export syntax" do
    source = ~s|export default await import("dep");|

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportDefaultDeclaration{
             declaration: %AST.AwaitExpression{
               argument: %AST.CallExpression{
                 callee: %AST.Identifier{name: "import"},
                 arguments: [%AST.Literal{value: "dep"}]
               }
             }
           } = statement
  end
end
