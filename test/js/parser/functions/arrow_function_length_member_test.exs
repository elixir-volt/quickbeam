defmodule QuickBEAM.JS.Parser.Functions.ArrowFunctionLengthMemberTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS arrow function length member syntax" do
    source = """
    ((a, b = 1, c) => {}).length;
    (({a, b}) => {}).length;
    """

    assert {:ok, %AST.Program{body: [default_params, pattern_params]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.MemberExpression{
               object: %AST.ArrowFunctionExpression{params: [_, %AST.AssignmentPattern{}, _]},
               property: %AST.Identifier{name: "length"}
             }
           } = default_params

    assert %AST.ExpressionStatement{
             expression: %AST.MemberExpression{
               object: %AST.ArrowFunctionExpression{params: [%AST.ObjectPattern{}]},
               property: %AST.Identifier{name: "length"}
             }
           } = pattern_params
  end
end
