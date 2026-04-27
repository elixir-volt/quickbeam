defmodule QuickBEAM.JS.Parser.Modules.DefaultArrowExportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible default arrow export syntax" do
    source = """
    export default async x => x;
    export default (x) => x;
    """

    assert {:ok, %AST.Program{body: [async_arrow, arrow]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportDefaultDeclaration{
             declaration: %AST.ArrowFunctionExpression{
               async: true,
               params: [%AST.Identifier{name: "x"}]
             }
           } = async_arrow

    assert %AST.ExportDefaultDeclaration{
             declaration: %AST.ArrowFunctionExpression{
               async: false,
               params: [%AST.Identifier{name: "x"}]
             }
           } = arrow
  end
end
