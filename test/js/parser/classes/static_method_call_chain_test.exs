defmodule QuickBEAM.JS.Parser.Classes.StaticMethodCallChainTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS static class method call syntax" do
    source = """
    C.F();
    D.F();
    D.G();
    D.H();
    E1.F();
    """

    assert {:ok, %AST.Program{body: statements}} = Parser.parse(source)
    assert length(statements) == 5

    assert Enum.map(statements, fn
             %AST.ExpressionStatement{
               expression: %AST.CallExpression{
                 callee: %AST.MemberExpression{
                   object: %AST.Identifier{name: object},
                   property: %AST.Identifier{name: property}
                 },
                 arguments: []
               }
             } ->
               {object, property}
           end) == [{"C", "F"}, {"D", "F"}, {"D", "G"}, {"D", "H"}, {"E1", "F"}]
  end
end
