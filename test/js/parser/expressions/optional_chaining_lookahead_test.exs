defmodule QuickBEAM.JS.Parser.Expressions.OptionalChainingLookaheadTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS optional chaining decimal lookahead" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{
                  declarations: [
                    %AST.VariableDeclarator{
                      init: %AST.ConditionalExpression{
                        consequent: %AST.Literal{value: 0.3},
                        alternate: %AST.Literal{value: false}
                      }
                    }
                  ]
                }
              ]
            }} = Parser.parse("const value = true ?.30 : false;")
  end

  test "ports QuickJS optional member access on constructed value" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.CallExpression{
                    arguments: [
                      %AST.Literal{value: 99},
                      %AST.MemberExpression{object: %AST.NewExpression{}, optional: true}
                    ]
                  }
                }
              ]
            }} = Parser.parse("assert.sameValue(99, new D(99)?.a);")
  end
end
