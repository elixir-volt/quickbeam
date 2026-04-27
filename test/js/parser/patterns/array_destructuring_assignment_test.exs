defmodule QuickBEAM.JS.Parser.Patterns.ArrayDestructuringAssignmentTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible array destructuring assignment rest syntax" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("[a, ...rest] = value;")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               left: %AST.ArrayPattern{
                 elements: [
                   %AST.Identifier{name: "a"},
                   %AST.RestElement{argument: %AST.Identifier{name: "rest"}}
                 ]
               },
               right: %AST.Identifier{name: "value"}
             }
           } = statement
  end
end
