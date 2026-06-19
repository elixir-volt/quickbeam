defmodule QuickBEAM.JS.Parser.Diagnostics.CoalesceMixingTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects unparenthesized coalesce mixed with logical and/or" do
    for source <- ["0 && 0 ?? true;", "0 || 0 ?? true;", "0 ?? 0 && true;", "0 ?? 0 || true;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "cannot mix ?? with && or ||"))
    end
  end

  test "allows parenthesized coalesce and logical combinations" do
    for source <- ["(0 && 0) ?? true;", "0 ?? (0 || true);"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
