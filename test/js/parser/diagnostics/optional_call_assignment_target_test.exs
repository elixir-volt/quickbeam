defmodule QuickBEAM.JS.Parser.Diagnostics.OptionalCallAssignmentTargetTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS optional call assignment target diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("object?.method() = value;")

    assert Enum.any?(errors, &(&1.message == "optional chain is not a valid assignment target"))
  end

  test "ports QuickJS optional call update target diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("object?.method()++;")

    assert Enum.any?(errors, &(&1.message == "optional chain is not a valid assignment target"))
  end
end
