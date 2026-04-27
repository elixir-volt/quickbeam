defmodule QuickBEAM.JS.Parser.ControlFlow.ContinueTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible continue and labeled continue syntax" do
    source = """
    loop: while (1) { continue loop; }
    for (;;) { continue; }
    """

    assert {:ok, %AST.Program{body: [labeled, loop]}} = Parser.parse(source)

    assert %AST.LabeledStatement{
             label: %AST.Identifier{name: "loop"},
             body: %AST.WhileStatement{
               body: %AST.BlockStatement{
                 body: [%AST.ContinueStatement{label: %AST.Identifier{name: "loop"}}]
               }
             }
           } = labeled

    assert %AST.ForStatement{
             body: %AST.BlockStatement{body: [%AST.ContinueStatement{label: nil}]}
           } = loop
  end
end
