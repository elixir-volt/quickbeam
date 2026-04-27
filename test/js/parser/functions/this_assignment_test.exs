defmodule QuickBEAM.JS.Parser.Functions.ThisAssignmentTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS constructor this-assignment syntax" do
    source = """
    function F(x) {
      this.x = x;
    }
    """

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.FunctionDeclaration{
             id: %AST.Identifier{name: "F"},
             params: [%AST.Identifier{name: "x"}],
             body: %AST.BlockStatement{
               body: [
                 %AST.ExpressionStatement{
                   expression: %AST.AssignmentExpression{
                     left: %AST.MemberExpression{
                       object: %AST.Identifier{name: "this"},
                       property: %AST.Identifier{name: "x"}
                     },
                     right: %AST.Identifier{name: "x"}
                   }
                 }
               ]
             }
           } = statement
  end
end
