defmodule QuickBEAM.JS.Parser.Functions.ArgumentsObjectTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS arguments object and call syntax" do
    source = """
    function f2() {
      arguments.length;
      arguments[0];
      arguments[1];
    }
    f2(1, 3);
    function f3(a) { arguments; gc(); }
    f3(0);
    """

    assert {:ok, %AST.Program{body: [f2, f2_call, f3, f3_call]}} = Parser.parse(source)

    assert %AST.FunctionDeclaration{
             id: %AST.Identifier{name: "f2"},
             body: %AST.BlockStatement{body: [length_stmt, first_arg_stmt, second_arg_stmt]}
           } = f2

    assert %AST.ExpressionStatement{
             expression: %AST.MemberExpression{property: %AST.Identifier{name: "length"}}
           } = length_stmt

    assert %AST.ExpressionStatement{
             expression: %AST.MemberExpression{computed: true, property: %AST.Literal{value: 0}}
           } = first_arg_stmt

    assert %AST.ExpressionStatement{
             expression: %AST.MemberExpression{computed: true, property: %AST.Literal{value: 1}}
           } = second_arg_stmt

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.Identifier{name: "f2"},
               arguments: [%AST.Literal{value: 1}, %AST.Literal{value: 3}]
             }
           } = f2_call

    assert %AST.FunctionDeclaration{id: %AST.Identifier{name: "f3"}} = f3

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.Identifier{name: "f3"},
               arguments: [%AST.Literal{value: 0}]
             }
           } = f3_call
  end
end
