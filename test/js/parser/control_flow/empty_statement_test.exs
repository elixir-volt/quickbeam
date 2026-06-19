defmodule QuickBEAM.JS.Parser.ControlFlow.EmptyStatementTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible empty statement syntax" do
    source = """
    ;
    while (ready) ;
    if (ready) ; else ;
    """

    assert {:ok, %AST.Program{body: [empty, while_statement, if_statement]}} =
             Parser.parse(source)

    assert %AST.EmptyStatement{} = empty
    assert %AST.WhileStatement{body: %AST.EmptyStatement{}} = while_statement

    assert %AST.IfStatement{consequent: %AST.EmptyStatement{}, alternate: %AST.EmptyStatement{}} =
             if_statement
  end
end
