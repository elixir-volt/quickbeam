defmodule QuickBEAM.JS.Parser.Patterns.ObjectDestructuringAssignmentTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible object destructuring assignment defaults" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("({ a, b = 1 } = obj);")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               left: %AST.ObjectPattern{
                 properties: [
                   %AST.Property{key: %AST.Identifier{name: "a"}, shorthand: true},
                   %AST.Property{
                     key: %AST.Identifier{name: "b"},
                     shorthand: true,
                     value: %AST.AssignmentPattern{
                       left: %AST.Identifier{name: "b"},
                       right: %AST.Literal{value: 1}
                     }
                   }
                 ]
               },
               right: %AST.Identifier{name: "obj"}
             }
           } = statement
  end
end
