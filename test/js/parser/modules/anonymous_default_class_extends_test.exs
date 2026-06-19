defmodule QuickBEAM.JS.Parser.Modules.AnonymousDefaultClassExtendsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible anonymous default class extends syntax" do
    source = "export default class extends Base { constructor() { super(); } }"

    assert {:ok, %AST.Program{source_type: :module, body: [statement]}} =
             Parser.parse(source, source_type: :module)

    assert %AST.ExportDefaultDeclaration{
             declaration: %AST.ClassDeclaration{
               id: nil,
               super_class: %AST.Identifier{name: "Base"},
               body: [
                 %AST.MethodDefinition{
                   kind: :constructor,
                   key: %AST.Identifier{name: "constructor"},
                   value: %AST.FunctionExpression{
                     body: %AST.BlockStatement{
                       body: [
                         %AST.ExpressionStatement{
                           expression: %AST.CallExpression{callee: %AST.Identifier{name: "super"}}
                         }
                       ]
                     }
                   }
                 }
               ]
             }
           } = statement
  end
end
