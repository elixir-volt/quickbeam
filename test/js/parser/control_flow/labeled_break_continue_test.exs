defmodule QuickBEAM.JS.Parser.ControlFlow.LabeledBreakContinueTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible labeled break and continue syntax" do
    source = """
    outer: for (;;) {
      inner: while (value) {
        continue outer;
        break inner;
      }
    }
    """

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.LabeledStatement{
             label: %AST.Identifier{name: "outer"},
             body: %AST.ForStatement{
               body: %AST.BlockStatement{
                 body: [
                   %AST.LabeledStatement{
                     label: %AST.Identifier{name: "inner"},
                     body: %AST.WhileStatement{
                       body: %AST.BlockStatement{
                         body: [
                           %AST.ContinueStatement{label: %AST.Identifier{name: "outer"}},
                           %AST.BreakStatement{label: %AST.Identifier{name: "inner"}}
                         ]
                       }
                     }
                   }
                 ]
               }
             }
           } = statement
  end
end
