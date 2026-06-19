defmodule QuickBEAM.JS.Parser.ControlFlow.BreakContinueLineTerminatorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible break and continue ASI line terminator syntax" do
    source = """
    loop: while (value) {
      break
      loop;
      continue
      loop;
    }
    """

    assert {:ok,
            %AST.Program{
              body: [
                %AST.LabeledStatement{
                  body: %AST.WhileStatement{body: %AST.BlockStatement{body: statements}}
                }
              ]
            }} =
             Parser.parse(source)

    assert [
             %AST.BreakStatement{label: nil},
             %AST.ExpressionStatement{expression: %AST.Identifier{name: "loop"}},
             %AST.ContinueStatement{label: nil},
             %AST.ExpressionStatement{expression: %AST.Identifier{name: "loop"}}
           ] = statements
  end
end
