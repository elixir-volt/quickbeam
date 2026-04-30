defmodule QuickBEAM.JS.Parser.ControlFlow.AwaitLabelTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS await label in script code" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.LabeledStatement{
                  label: %AST.Identifier{name: "await"},
                  body: %AST.ExpressionStatement{expression: %AST.Literal{value: 1}}
                }
              ]
            }} = Parser.parse("await: 1;")
  end
end
