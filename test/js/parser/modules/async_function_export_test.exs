defmodule QuickBEAM.JS.Parser.Modules.AsyncFunctionExportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible async function export syntax" do
    source = """
    export async function f() {}
    export default async function g() {}
    export default async function *h() {}
    """

    assert {:ok, %AST.Program{body: [named_export, default_async, default_async_generator]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportNamedDeclaration{
             declaration: %AST.FunctionDeclaration{async: true, generator: false}
           } = named_export

    assert %AST.ExportDefaultDeclaration{
             declaration: %AST.FunctionDeclaration{async: true, generator: false}
           } = default_async

    assert %AST.ExportDefaultDeclaration{
             declaration: %AST.FunctionDeclaration{async: true, generator: true}
           } = default_async_generator
  end
end
