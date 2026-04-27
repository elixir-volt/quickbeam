defmodule QuickBEAM.JS.Parser.ControlFlow.SwitchTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS assert_throws switch syntax" do
    source = """
    switch (typeof func) {
    case 'string':
      eval(func);
      break;
    case 'function':
      func();
      break;
    default:
      break;
    }
    """

    assert {:ok, %AST.Program{body: [%AST.SwitchStatement{} = switch]}} = Parser.parse(source)

    assert %AST.SwitchStatement{
             discriminant: %AST.UnaryExpression{operator: "typeof"},
             cases: [
               %AST.SwitchCase{
                 test: %AST.Literal{value: "string"},
                 consequent: [_, %AST.BreakStatement{}]
               },
               %AST.SwitchCase{
                 test: %AST.Literal{value: "function"},
                 consequent: [_, %AST.BreakStatement{}]
               },
               %AST.SwitchCase{test: nil, consequent: [%AST.BreakStatement{}]}
             ]
           } = switch
  end
end
