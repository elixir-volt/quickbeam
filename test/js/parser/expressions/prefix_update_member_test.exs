defmodule QuickBEAM.JS.Parser.Expressions.PrefixUpdateMemberTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS prefix update member and index syntax" do
    source = """
    ++a.x;
    --a[0];
    """

    assert {:ok, %AST.Program{body: [member_update, index_update]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.UpdateExpression{
               operator: "++",
               prefix: true,
               argument: %AST.MemberExpression{computed: false}
             }
           } = member_update

    assert %AST.ExpressionStatement{
             expression: %AST.UpdateExpression{
               operator: "--",
               prefix: true,
               argument: %AST.MemberExpression{computed: true}
             }
           } = index_update
  end
end
