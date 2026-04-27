defmodule QuickBEAM.JS.Parser.ControlFlow.CatchInstanceofAssignmentTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS catch instanceof assignment syntax" do
    source = """
    try { delete null.a; }
    catch (e) { err = (e instanceof TypeError); }
    """

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.TryStatement{
             block: %AST.BlockStatement{
               body: [
                 %AST.ExpressionStatement{expression: %AST.UnaryExpression{operator: "delete"}}
               ]
             },
             handler: %AST.CatchClause{
               param: %AST.Identifier{name: "e"},
               body: %AST.BlockStatement{
                 body: [
                   %AST.ExpressionStatement{
                     expression: %AST.AssignmentExpression{
                       left: %AST.Identifier{name: "err"},
                       right: %AST.BinaryExpression{
                         operator: "instanceof",
                         left: %AST.Identifier{name: "e"},
                         right: %AST.Identifier{name: "TypeError"}
                       }
                     }
                   }
                 ]
               }
             }
           } = statement
  end
end
