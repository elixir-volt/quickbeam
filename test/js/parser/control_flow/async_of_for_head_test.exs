defmodule QuickBEAM.JS.Parser.ControlFlow.AsyncOfForHeadTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS async of arrow as classic for initializer" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ForStatement{
                  init: %AST.ArrowFunctionExpression{
                    params: [%AST.Identifier{name: "of"}]
                  }
                }
              ]
            }} = Parser.parse("for (async of => {}; i < 10; ++i) { }")
  end
end
