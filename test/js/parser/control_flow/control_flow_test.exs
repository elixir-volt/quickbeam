defmodule QuickBEAM.JS.Parser.ControlFlow.ControlFlowTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS labeled statement parse coverage" do
    source = """
    do x: { break x; } while(0);
    if (1)
        x: { break x; }
    else
        x: { break x; }
    with ({}) x: { break x; };
    while (0) x: { break x; };
    """

    assert {:ok,
            %AST.Program{body: [do_while, if_stmt, with_stmt, while_stmt, %AST.EmptyStatement{}]}} =
             Parser.parse(source)

    assert %AST.DoWhileStatement{body: %AST.LabeledStatement{label: %AST.Identifier{name: "x"}}} =
             do_while

    assert %AST.IfStatement{
             consequent: %AST.LabeledStatement{},
             alternate: %AST.LabeledStatement{}
           } = if_stmt

    assert %AST.WithStatement{body: %AST.LabeledStatement{}} = with_stmt
    assert %AST.WhileStatement{body: %AST.LabeledStatement{}} = while_stmt
  end
end
