defmodule QuickBEAM.JS.Parser.Literals.NumberLiteralMemberTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS number literal member access syntax" do
    for source <- ["0.1.a;", "0x1.a;", "0b1.a;", "0o1.a;"] do
      assert {:ok, %AST.Program{body: [%AST.ExpressionStatement{expression: expression}]}} =
               Parser.parse(source)

      assert %AST.MemberExpression{property: %AST.Identifier{name: "a"}} = expression
    end
  end
end
