defmodule QuickBEAM.JS.Parser.Patterns.FunctionLengthPatternTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS function-length parameter pattern syntax" do
    source = """
    f = ([a, b]) => {};
    g = ({a, b}) => {};
    h = (c, [a, b] = 1, d) => {};
    """

    assert {:ok, %AST.Program{body: [array_param, object_param, default_pattern_param]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ArrowFunctionExpression{params: [%AST.ArrayPattern{}]}
             }
           } = array_param

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ArrowFunctionExpression{params: [%AST.ObjectPattern{}]}
             }
           } = object_param

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ArrowFunctionExpression{
                 params: [
                   %AST.Identifier{name: "c"},
                   %AST.AssignmentPattern{left: %AST.ArrayPattern{}},
                   %AST.Identifier{name: "d"}
                 ]
               }
             }
           } = default_pattern_param
  end
end
