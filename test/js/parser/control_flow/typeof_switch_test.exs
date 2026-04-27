defmodule QuickBEAM.JS.Parser.ControlFlow.TypeofSwitchTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS typeof switch dispatch syntax" do
    source = """
    switch (typeof func) {
      case "function": break;
      default: throw Error("bad");
    }
    """

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.SwitchStatement{
             discriminant: %AST.UnaryExpression{
               operator: "typeof",
               argument: %AST.Identifier{name: "func"}
             },
             cases: [
               %AST.SwitchCase{
                 test: %AST.Literal{value: "function"},
                 consequent: [%AST.BreakStatement{}]
               },
               %AST.SwitchCase{
                 test: nil,
                 consequent: [
                   %AST.ThrowStatement{
                     argument: %AST.CallExpression{callee: %AST.Identifier{name: "Error"}}
                   }
                 ]
               }
             ]
           } = statement
  end
end
