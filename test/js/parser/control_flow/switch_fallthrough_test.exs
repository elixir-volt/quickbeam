defmodule QuickBEAM.JS.Parser.ControlFlow.SwitchFallthroughTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible switch fallthrough syntax" do
    source = """
    switch (value) {
      case 1:
      case 2:
        value += 1;
        break;
      default:
        value = 0;
    }
    """

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.SwitchStatement{
             discriminant: %AST.Identifier{name: "value"},
             cases: [
               %AST.SwitchCase{test: %AST.Literal{value: 1}, consequent: []},
               %AST.SwitchCase{
                 test: %AST.Literal{value: 2},
                 consequent: [%AST.ExpressionStatement{}, %AST.BreakStatement{}]
               },
               %AST.SwitchCase{
                 test: nil,
                 consequent: [
                   %AST.ExpressionStatement{expression: %AST.AssignmentExpression{operator: "="}}
                 ]
               }
             ]
           } = statement
  end
end
