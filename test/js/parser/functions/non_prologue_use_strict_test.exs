defmodule QuickBEAM.JS.Parser.Functions.NonPrologueUseStrictTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible non-prologue use strict string syntax" do
    source = ~S|function f(a, a) { setup(); "use strict"; return a; }|

    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{
                  params: [%AST.Identifier{name: "a"}, %AST.Identifier{name: "a"}],
                  body: body
                }
              ]
            }} =
             Parser.parse(source)

    assert %AST.BlockStatement{
             body: [
               %AST.ExpressionStatement{
                 expression: %AST.CallExpression{callee: %AST.Identifier{name: "setup"}}
               },
               %AST.ExpressionStatement{expression: %AST.Literal{value: "use strict"}},
               %AST.ReturnStatement{}
             ]
           } = body
  end
end
