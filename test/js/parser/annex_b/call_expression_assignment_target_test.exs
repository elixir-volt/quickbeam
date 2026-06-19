defmodule QuickBEAM.JS.Parser.AnnexB.CallExpressionAssignmentTargetTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "accepts Annex B call expression assignment targets for web compatibility" do
    for source <- ["f() = g();", "f() += g();"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "accepts Annex B call expression update targets for web compatibility" do
    for source <- ["f()++;", "++f();"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "accepts Annex B call expression for-in/of targets for web compatibility" do
    for source <- ["for (f() in object) {}", "for (f() of object) {}"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
