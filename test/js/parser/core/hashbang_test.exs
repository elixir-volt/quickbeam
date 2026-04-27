defmodule QuickBEAM.JS.Parser.Core.HashbangTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible hashbang comment syntax" do
    source = """
    #!/usr/bin/env quickjs
    value = 1;
    """

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               left: %AST.Identifier{name: "value"},
               right: %AST.Literal{value: 1}
             }
           } = statement
  end
end
