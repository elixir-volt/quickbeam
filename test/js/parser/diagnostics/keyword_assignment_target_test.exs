defmodule QuickBEAM.JS.Parser.Diagnostics.KeywordAssignmentTargetTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS this and super assignment target diagnostics" do
    for source <- ["this = 1;", "class C extends B { method() { super = value; } }"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid assignment target"))
    end
  end

  test "preserves this and super member assignment targets" do
    for source <- ["this.value = 1;", "class C extends B { method() { super.value = 1; } }"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
