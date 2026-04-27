defmodule QuickBEAM.JS.Parser.Diagnostics.FutureReservedWordsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows strict-mode future reserved words as sloppy bindings" do
    for name <- ~w[implements interface package private protected public] do
      assert {:ok,
              %AST.Program{
                body: [
                  %AST.VariableDeclaration{
                    declarations: [%AST.VariableDeclarator{id: %AST.Identifier{name: ^name}}]
                  }
                ]
              }} = Parser.parse("var #{name};")
    end
  end

  test "rejects strict-mode future reserved words in strict bindings" do
    for name <- ~w[implements interface package private protected public] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(~s|"use strict"; var #{name};|)
      assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
    end
  end

  test "allows strict-mode future reserved words as sloppy identifier references" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.UnaryExpression{
                    operator: "typeof",
                    argument: %AST.Identifier{name: "public"}
                  }
                }
              ]
            }} = Parser.parse("typeof public;")
  end
end
