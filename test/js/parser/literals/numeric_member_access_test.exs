defmodule QuickBEAM.JS.Parser.Literals.NumericMemberAccessTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "accepts hexadecimal literals ending in exponent letters" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.CallExpression{
                    arguments: [
                      %AST.Literal{value: 0x7FFFFFFE, raw: "0x7ffffffe"}
                    ]
                  }
                }
              ]
            }} = Parser.parse("assert(0x7ffffffe);")
  end

  test "parses legacy leading-zero integer member access" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.CallExpression{
                    arguments: [
                      %AST.MemberExpression{
                        object: %AST.Literal{raw: "01"},
                        property: %AST.Identifier{name: "a"},
                        computed: false
                      }
                    ]
                  }
                }
              ]
            }} = Parser.parse("assert(01.a);")
  end

  test "keeps zero-dot identifier syntax invalid" do
    assert {:error, _program, errors} = Parser.parse("0.a;")
    assert Enum.any?(errors, &(&1.message == "invalid number literal"))
  end
end
