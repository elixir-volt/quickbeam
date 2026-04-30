defmodule QuickBEAM.JS.Parser.Diagnostics.InvalidAssignmentTargetTest do
  use ExUnit.Case, async: true
  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects binary expression assignment targets" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("(a + b) = value;")

    assert Enum.any?(errors, &(&1.message == "invalid assignment target"))
  end

  test "accepts Annex B call expression assignment targets" do
    assert {:ok, %AST.Program{body: [%AST.ExpressionStatement{}]}} =
             Parser.parse("call() = value;")
  end

  test "accepts Annex B call expression update targets" do
    assert {:ok, %AST.Program{body: [%AST.ExpressionStatement{}]}} = Parser.parse("call()++;")
  end
end
