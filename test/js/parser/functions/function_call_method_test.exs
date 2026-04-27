defmodule QuickBEAM.JS.Parser.Functions.FunctionCallMethodTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS function call method syntax" do
    source = """
    f.call(123);
    f(12)()[0];
    f(12)()[0].value;
    """

    assert {:ok, %AST.Program{body: [call_method, nested_call_index, nested_call_member]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.MemberExpression{
                 object: %AST.Identifier{name: "f"},
                 property: %AST.Identifier{name: "call"}
               },
               arguments: [%AST.Literal{value: 123}]
             }
           } = call_method

    assert %AST.ExpressionStatement{
             expression: %AST.MemberExpression{
               object: %AST.CallExpression{callee: %AST.CallExpression{}},
               computed: true
             }
           } = nested_call_index

    assert %AST.ExpressionStatement{
             expression: %AST.MemberExpression{
               object: %AST.MemberExpression{
                 object: %AST.CallExpression{callee: %AST.CallExpression{}},
                 computed: true
               },
               property: %AST.Identifier{name: "value"}
             }
           } = nested_call_member
  end
end
