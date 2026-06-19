defmodule QuickBEAM.JS.Parser.ControlFlow.ForAwaitTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible for-await-of syntax" do
    source = "async function f(iterable) { for await (const value of iterable) { await value; } }"

    assert {:ok,
            %AST.Program{
              body: [%AST.FunctionDeclaration{body: %AST.BlockStatement{body: [loop]}}]
            }} = Parser.parse(source)

    assert %AST.ForOfStatement{
             await: true,
             left: %AST.VariableDeclaration{kind: :const},
             right: %AST.Identifier{name: "iterable"},
             body: %AST.BlockStatement{}
           } = loop
  end
end
