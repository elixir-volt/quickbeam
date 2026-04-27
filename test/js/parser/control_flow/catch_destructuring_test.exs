defmodule QuickBEAM.JS.Parser.ControlFlow.CatchDestructuringTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible catch destructuring binding syntax" do
    source = """
    try { throw error; } catch ({ message, code = 1 }) { handle(message); }
    try { throw error; } catch ([first, ...rest]) { handle(first); }
    """

    assert {:ok, %AST.Program{body: [object_catch, array_catch]}} = Parser.parse(source)

    assert %AST.TryStatement{
             handler: %AST.CatchClause{
               param: %AST.ObjectPattern{
                 properties: [%AST.Property{}, %AST.Property{value: %AST.AssignmentPattern{}}]
               }
             }
           } = object_catch

    assert %AST.TryStatement{
             handler: %AST.CatchClause{
               param: %AST.ArrayPattern{
                 elements: [
                   %AST.Identifier{name: "first"},
                   %AST.RestElement{argument: %AST.Identifier{name: "rest"}}
                 ]
               }
             }
           } = array_catch
  end
end
