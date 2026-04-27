defmodule QuickBEAM.JS.Parser.Literals.RegExpMemberTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS regexp literal member and return syntax" do
    source = """
    function f() { return /abc/g; }
    /abc/.test(value);
    """

    assert {:ok, %AST.Program{body: [function_decl, call_statement]}} = Parser.parse(source)

    assert %AST.FunctionDeclaration{
             body: %AST.BlockStatement{
               body: [
                 %AST.ReturnStatement{
                   argument: %AST.Literal{value: %{pattern: "abc", flags: "g"}}
                 }
               ]
             }
           } = function_decl

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.MemberExpression{
                 object: %AST.Literal{value: %{pattern: "abc", flags: ""}},
                 property: %AST.Identifier{name: "test"}
               },
               arguments: [%AST.Identifier{name: "value"}]
             }
           } = call_statement
  end
end
