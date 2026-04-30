defmodule QuickBEAM.JS.Parser.Diagnostics.AwaitContextTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module await expression context diagnostics" do
    assert {:ok, %AST.Program{body: [%AST.ExpressionStatement{}]}} =
             Parser.parse("await value;", source_type: :module)
  end

  test "ports QuickJS module await regexp expression syntax" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.AwaitExpression{argument: %AST.Literal{raw: "/x.y/g"}}
                }
              ]
            }} = Parser.parse("await /x.y/g;", source_type: :module)
  end

  test "ports QuickJS script await identifier syntax" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{
                  declarations: [%AST.VariableDeclarator{id: %AST.Identifier{name: "await"}}]
                },
                %AST.ExpressionStatement{expression: %AST.Identifier{name: "await"}}
              ]
            }} = Parser.parse("var await = 1; await;")
  end

  test "ports QuickJS non-async function await identifier syntax" do
    assert {:ok, %AST.Program{body: [%AST.FunctionDeclaration{}]}} =
             Parser.parse("function f() { var await = 1; await; }")
  end
end
