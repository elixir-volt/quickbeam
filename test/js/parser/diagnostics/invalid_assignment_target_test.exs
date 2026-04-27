defmodule QuickBEAM.JS.Parser.Diagnostics.InvalidAssignmentTargetTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS binary expression assignment target diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("(a + b) = value;")

    assert Enum.any?(errors, &(&1.message == "invalid assignment target"))
  end

  test "ports Annex B sloppy call expression assignment target syntax" do
    assert {:ok, %AST.Program{body: [%AST.ExpressionStatement{}]}} =
             Parser.parse("call() = value;")
  end

  test "ports Annex B sloppy call expression update target syntax" do
    assert {:ok, %AST.Program{body: [%AST.ExpressionStatement{}]}} = Parser.parse("call()++;")
  end
end
