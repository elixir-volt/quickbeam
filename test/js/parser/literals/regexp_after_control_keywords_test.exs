defmodule QuickBEAM.JS.Parser.Literals.RegexpAfterControlKeywordsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible regexp literals after control-flow keywords" do
    source = """
    if (/ok/.test(value)) { matched = true; }
    while (/again/.test(next())) { break; }
    switch (value) { case /case/: break; }
    """

    assert {:ok, %AST.Program{body: [if_statement, while_statement, switch_statement]}} =
             Parser.parse(source)

    assert %AST.IfStatement{
             test: %AST.CallExpression{
               callee: %AST.MemberExpression{object: %AST.Literal{value: %{pattern: "ok"}}}
             }
           } = if_statement

    assert %AST.WhileStatement{
             test: %AST.CallExpression{
               callee: %AST.MemberExpression{object: %AST.Literal{value: %{pattern: "again"}}}
             }
           } = while_statement

    assert %AST.SwitchStatement{
             cases: [%AST.SwitchCase{test: %AST.Literal{value: %{pattern: "case"}}}]
           } = switch_statement
  end
end
