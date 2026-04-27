defmodule QuickBEAM.JS.Parser.Classes.InstanceMethodCallChainTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS class instance method call-chain syntax" do
    source = """
    new P().get();
    new P().set();
    new P().async();
    new P().static();
    """

    assert {:ok, %AST.Program{body: statements}} = Parser.parse(source)
    assert length(statements) == 4

    assert Enum.map(statements, fn
             %AST.ExpressionStatement{
               expression: %AST.CallExpression{
                 callee: %AST.MemberExpression{
                   object: %AST.NewExpression{callee: %AST.Identifier{name: "P"}},
                   property: %AST.Identifier{name: name}
                 }
               }
             } ->
               name
           end) == ["get", "set", "async", "static"]
  end
end
