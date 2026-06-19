defmodule QuickBEAM.JS.Parser.Modules.DefaultExportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible default export syntax" do
    source = """
    export default function f() { return 1; }
    export default class C {}
    export default value + 1;
    """

    assert {:ok, %AST.Program{body: [fun_export, class_export, expr_export]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportDefaultDeclaration{
             declaration: %AST.FunctionDeclaration{id: %AST.Identifier{name: "f"}}
           } = fun_export

    assert %AST.ExportDefaultDeclaration{
             declaration: %AST.ClassDeclaration{id: %AST.Identifier{name: "C"}}
           } = class_export

    assert %AST.ExportDefaultDeclaration{declaration: %AST.BinaryExpression{operator: "+"}} =
             expr_export
  end
end
