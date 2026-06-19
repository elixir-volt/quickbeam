defmodule QuickBEAM.JS.Parser.Expressions.GroupedOptionalCallTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS grouped optional member call syntax" do
    source = """
    (a?.b)().c;
    (a?.["b"])().c;
    """

    assert {:ok, %AST.Program{body: [member_call, computed_call]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.MemberExpression{
               object: %AST.CallExpression{
                 callee: %AST.MemberExpression{optional: true, computed: false}
               },
               property: %AST.Identifier{name: "c"}
             }
           } = member_call

    assert %AST.ExpressionStatement{
             expression: %AST.MemberExpression{
               object: %AST.CallExpression{
                 callee: %AST.MemberExpression{optional: true, computed: true}
               },
               property: %AST.Identifier{name: "c"}
             }
           } = computed_call
  end
end
