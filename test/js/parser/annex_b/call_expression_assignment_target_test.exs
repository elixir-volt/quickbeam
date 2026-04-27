defmodule QuickBEAM.JS.Parser.AnnexB.CallExpressionAssignmentTargetTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports Annex B call expression assignment targets" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.AssignmentExpression{left: %AST.CallExpression{}}
                }
              ]
            }} = Parser.parse("f() = g();")
  end

  test "ports Annex B call expression update targets" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.UpdateExpression{argument: %AST.CallExpression{}}
                }
              ]
            }} = Parser.parse("f()++;")
  end
end
