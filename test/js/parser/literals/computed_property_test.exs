defmodule QuickBEAM.JS.Parser.Literals.ComputedPropertyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible computed object property syntax" do
    source = ~s|value = { [name]: 1, [method]() { return 2; } };|

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{
                 properties: [
                   %AST.Property{key: %AST.Identifier{name: "name"}, computed: true},
                   %AST.Property{
                     key: %AST.Identifier{name: "method"},
                     computed: true,
                     method: true
                   }
                 ]
               }
             }
           } = statement
  end
end
