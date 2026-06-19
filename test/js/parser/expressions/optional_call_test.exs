defmodule QuickBEAM.JS.Parser.Expressions.OptionalCallTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible optional call syntax" do
    source = """
    fn?.();
    obj.method?.();
    obj?.method?.(x);
    """

    assert {:ok, %AST.Program{body: [direct_call, method_call, chained_call]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{callee: %AST.Identifier{name: "fn"}, optional: true}
           } = direct_call

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.MemberExpression{property: %AST.Identifier{name: "method"}},
               optional: true
             }
           } = method_call

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.MemberExpression{optional: true},
               arguments: [%AST.Identifier{name: "x"}],
               optional: true
             }
           } = chained_call
  end
end
