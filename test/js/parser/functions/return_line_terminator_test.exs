defmodule QuickBEAM.JS.Parser.Functions.ReturnLineTerminatorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible return ASI line terminator syntax" do
    source = """
    function f() {
      return
      value;
    }
    """

    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{
                  body: %AST.BlockStatement{body: [return_statement, expression_statement]}
                }
              ]
            }} =
             Parser.parse(source)

    assert %AST.ReturnStatement{argument: nil} = return_statement

    assert %AST.ExpressionStatement{expression: %AST.Identifier{name: "value"}} =
             expression_statement
  end
end
