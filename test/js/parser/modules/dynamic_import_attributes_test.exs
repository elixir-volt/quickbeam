defmodule QuickBEAM.JS.Parser.Modules.DynamicImportAttributesTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible dynamic import attributes syntax" do
    source = ~s|module = import("./data.json", { with: { type: "json" } });|

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.CallExpression{
                 callee: %AST.Identifier{name: "import"},
                 arguments: [
                   %AST.Literal{value: "./data.json"},
                   %AST.ObjectExpression{
                     properties: [%AST.Property{key: %AST.Identifier{name: "with"}}]
                   }
                 ]
               }
             }
           } = statement
  end
end
