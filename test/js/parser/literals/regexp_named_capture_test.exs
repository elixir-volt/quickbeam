defmodule QuickBEAM.JS.Parser.Literals.RegexpNamedCaptureTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible regexp named capture syntax" do
    assert {:ok, %AST.Program{body: [statement]}} =
             Parser.parse("pattern = /(?<name>[a-z]+)\\k<name>/u;")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.Literal{value: %{pattern: "(?<name>[a-z]+)\\k<name>", flags: "u"}}
             }
           } = statement
  end
end
