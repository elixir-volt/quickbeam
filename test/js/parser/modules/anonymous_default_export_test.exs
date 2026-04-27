defmodule QuickBEAM.JS.Parser.Modules.AnonymousDefaultExportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible anonymous default function and class export syntax" do
    source = """
    export default function() { return 1; }
    export default async function() { return 2; }
    export default class {}
    """

    assert {:ok, %AST.Program{body: [function_export, async_function_export, class_export]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportDefaultDeclaration{
             declaration: %AST.FunctionDeclaration{id: nil, async: false}
           } =
             function_export

    assert %AST.ExportDefaultDeclaration{
             declaration: %AST.FunctionDeclaration{id: nil, async: true}
           } =
             async_function_export

    assert %AST.ExportDefaultDeclaration{declaration: %AST.ClassDeclaration{id: nil}} =
             class_export
  end
end
