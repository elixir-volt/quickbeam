defmodule QuickBEAM.JS.Parser.Diagnostics.CallLogicalAssignmentTargetTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects call expressions as logical assignment targets" do
    for source <- ["f() &&= 1;", "f() ||= 1;", "f() ??= 1;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid assignment target"))
    end
  end

  test "preserves sloppy Annex B direct and compound call assignment targets" do
    for source <- ["f() = 1;", "f() += 1;"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
