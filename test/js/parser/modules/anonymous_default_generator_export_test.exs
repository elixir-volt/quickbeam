defmodule QuickBEAM.JS.Parser.Modules.AnonymousDefaultGeneratorExportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible anonymous default generator export syntax" do
    source = """
    export default function*() { yield 1; }
    export default async function*() { yield await value; }
    """

    assert {:ok, %AST.Program{body: [generator_export, async_generator_export]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportDefaultDeclaration{
             declaration: %AST.FunctionDeclaration{id: nil, async: false, generator: true}
           } = generator_export

    assert %AST.ExportDefaultDeclaration{
             declaration: %AST.FunctionDeclaration{id: nil, async: true, generator: true}
           } = async_generator_export
  end
end
