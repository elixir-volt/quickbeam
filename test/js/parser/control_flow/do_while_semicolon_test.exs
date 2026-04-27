defmodule QuickBEAM.JS.Parser.ControlFlow.DoWhileSemicolonTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible do-while optional semicolon syntax" do
    source = """
    do { value++; } while (value < 3)
    value;
    """

    assert {:ok, %AST.Program{body: [loop, expression]}} = Parser.parse(source)

    assert %AST.DoWhileStatement{
             body: %AST.BlockStatement{
               body: [%AST.ExpressionStatement{expression: %AST.UpdateExpression{operator: "++"}}]
             },
             test: %AST.BinaryExpression{operator: "<"}
           } = loop

    assert %AST.ExpressionStatement{expression: %AST.Identifier{name: "value"}} = expression
  end
end
