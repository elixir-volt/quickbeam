defmodule QuickBEAM.JS.Parser.Patterns.AssignmentPatternASTTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible assignment destructuring pattern AST shape" do
    source = "({ a: { b }, c: [first, ...tail] } = object);"

    assert {:ok, %AST.Program{body: [%AST.ExpressionStatement{expression: assignment}]}} =
             Parser.parse(source)

    assert %AST.AssignmentExpression{
             left: %AST.ObjectPattern{
               properties: [
                 %AST.Property{
                   value: %AST.ObjectPattern{
                     properties: [%AST.Property{key: %AST.Identifier{name: "b"}}]
                   }
                 },
                 %AST.Property{
                   value: %AST.ArrayPattern{
                     elements: [
                       %AST.Identifier{name: "first"},
                       %AST.RestElement{argument: %AST.Identifier{name: "tail"}}
                     ]
                   }
                 }
               ]
             },
             right: %AST.Identifier{name: "object"}
           } = assignment
  end
end
