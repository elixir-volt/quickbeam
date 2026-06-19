defmodule QuickBEAM.JS.Parser.Patterns.ObjectRestAssignmentTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible object rest destructuring assignment syntax" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("({ a, ...rest } = object);")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               left: %AST.ObjectPattern{
                 properties: [
                   %AST.Property{key: %AST.Identifier{name: "a"}, shorthand: true},
                   %AST.RestElement{argument: %AST.Identifier{name: "rest"}}
                 ]
               },
               right: %AST.Identifier{name: "object"}
             }
           } = statement
  end
end
