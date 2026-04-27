defmodule QuickBEAM.JS.Parser.Literals.DoubleDotNumericMemberAccessTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS integer literal member access with double dot" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.CallExpression{
                    callee: %AST.MemberExpression{
                      object: %AST.Literal{value: 1.0, raw: "1."},
                      property: %AST.Identifier{name: "toString"}
                    }
                  }
                }
              ]
            }} = Parser.parse("1..toString();")
  end
end
