defmodule QuickBEAM.JS.Parser.ControlFlow.ForLoopTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible for loop syntax" do
    source = """
    for (var i = 0; i < 3; i++) { assert(i); }
    for (x in obj) { break; }
    for (let x of xs) { assert(x); }
    """

    assert {:ok, %AST.Program{body: [classic, for_in, for_of]}} = Parser.parse(source)

    assert %AST.ForStatement{
             init: %AST.VariableDeclaration{},
             test: %AST.BinaryExpression{operator: "<"},
             update: %AST.UpdateExpression{operator: "++"},
             body: %AST.BlockStatement{}
           } = classic

    assert %AST.ForInStatement{
             left: %AST.Identifier{name: "x"},
             right: %AST.Identifier{name: "obj"}
           } = for_in

    assert %AST.ForOfStatement{
             left: %AST.VariableDeclaration{},
             right: %AST.Identifier{name: "xs"}
           } = for_of
  end
end
