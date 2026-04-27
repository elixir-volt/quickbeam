defmodule QuickBEAM.JS.Parser.ControlFlow.SwitchDefaultMiddleTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible switch default in middle syntax" do
    source = """
    switch (value) {
      case 0: zero();
      default: fallback();
      case 1: one();
    }
    """

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.SwitchStatement{
             cases: [
               %AST.SwitchCase{
                 test: %AST.Literal{value: 0},
                 consequent: [%AST.ExpressionStatement{}]
               },
               %AST.SwitchCase{test: nil, consequent: [%AST.ExpressionStatement{}]},
               %AST.SwitchCase{
                 test: %AST.Literal{value: 1},
                 consequent: [%AST.ExpressionStatement{}]
               }
             ]
           } = statement
  end
end
