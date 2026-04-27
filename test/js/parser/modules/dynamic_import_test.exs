defmodule QuickBEAM.JS.Parser.Modules.DynamicImportTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible dynamic import expression syntax" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(~s|value = import("mod");|)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.CallExpression{
                 callee: %AST.Identifier{name: "import"},
                 arguments: [%AST.Literal{value: "mod"}]
               }
             }
           } = statement
  end
end
