defmodule QuickBEAM.JS.Parser.Diagnostics.ParenthesizedObjectAssignmentTargetTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects parenthesized object literal as a direct assignment target" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("({}) = 1;")
    assert Enum.any?(errors, &(&1.message == "invalid assignment target"))
  end

  test "preserves parenthesized object destructuring assignment" do
    assert {:ok, %AST.Program{}} = Parser.parse("({} = value);")
  end
end
