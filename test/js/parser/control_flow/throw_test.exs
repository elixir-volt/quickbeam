defmodule QuickBEAM.JS.Parser.ControlFlow.ThrowTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS assert helper throw syntax" do
    assert {:ok, %AST.Program{body: [statement]}} =
             Parser.parse(~s|throw Error("assertion failed");|)

    assert %AST.ThrowStatement{
             argument: %AST.CallExpression{callee: %AST.Identifier{name: "Error"}}
           } = statement
  end

  test "ports QuickJS throw restricted production line terminator error" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("throw\nError('x')")
    assert Enum.any?(errors, &(&1.message == "line terminator after throw"))
  end
end
