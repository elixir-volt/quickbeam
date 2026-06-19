defmodule QuickBEAM.JS.Parser.Classes.AnonymousClassExpressionExtendsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible anonymous class expression with extends syntax" do
    source = "value = class extends Base { method() { return super.method(); } };"

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ClassExpression{
                 id: nil,
                 super_class: %AST.Identifier{name: "Base"},
                 body: [
                   %AST.MethodDefinition{
                     key: %AST.Identifier{name: "method"},
                     value: %AST.FunctionExpression{
                       body: %AST.BlockStatement{
                         body: [%AST.ReturnStatement{argument: %AST.CallExpression{}}]
                       }
                     }
                   }
                 ]
               }
             }
           } = statement
  end
end
