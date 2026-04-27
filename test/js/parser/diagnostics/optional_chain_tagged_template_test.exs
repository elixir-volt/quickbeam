defmodule QuickBEAM.JS.Parser.Diagnostics.OptionalChainTaggedTemplateTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS optional chain tagged template diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("tag?.method`template`;")

    assert Enum.any?(
             errors,
             &(&1.message == "optional chain not allowed as tagged template callee")
           )
  end

  test "ports QuickJS regular tagged template allowance" do
    assert {:ok,
            %AST.Program{
              body: [%AST.ExpressionStatement{expression: %AST.TaggedTemplateExpression{}}]
            }} = Parser.parse("tag`template`;")
  end
end
