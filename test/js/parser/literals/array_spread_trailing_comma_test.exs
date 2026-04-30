defmodule QuickBEAM.JS.Parser.Literals.ArraySpreadTrailingCommaTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "preserves trailing comma after array spread" do
    assert {:ok, %AST.Program{body: [%AST.ExpressionStatement{expression: array}]}} =
             Parser.parse("[...items,];")

    assert %AST.ArrayExpression{elements: [%AST.SpreadElement{}, nil]} = array
  end
end
