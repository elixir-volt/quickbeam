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

  test "ports QuickJS call expression assignment target diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("call() = value;")

    assert Enum.any?(errors, &(&1.message == "invalid assignment target"))
  end

  test "ports QuickJS call expression update target diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("call()++;")

    assert Enum.any?(errors, &(&1.message == "invalid assignment target"))
  end
end
