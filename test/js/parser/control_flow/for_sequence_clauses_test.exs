defmodule QuickBEAM.JS.Parser.ControlFlow.ForSequenceClausesTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible for loop sequence clauses" do
    source = "for (i = 0, j = 1; i < j; i++, j--) { continue; }"

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ForStatement{
             init: %AST.SequenceExpression{
               expressions: [%AST.AssignmentExpression{}, %AST.AssignmentExpression{}]
             },
             test: %AST.BinaryExpression{operator: "<"},
             update: %AST.SequenceExpression{
               expressions: [
                 %AST.UpdateExpression{operator: "++"},
                 %AST.UpdateExpression{operator: "--"}
               ]
             },
             body: %AST.BlockStatement{body: [%AST.ContinueStatement{}]}
           } = statement
  end
end
