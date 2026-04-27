defmodule QuickBEAM.JS.Parser.Diagnostics.OptionalChainAssignmentTargetTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS optional chain assignment target diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("object?.property = value;")

    assert Enum.any?(errors, &(&1.message == "optional chain is not a valid assignment target"))
  end

  test "ports QuickJS optional chain update target diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("object?.property++;")

    assert Enum.any?(errors, &(&1.message == "optional chain is not a valid assignment target"))
  end
end
