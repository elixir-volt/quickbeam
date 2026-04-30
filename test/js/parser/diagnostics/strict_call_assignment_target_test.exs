defmodule QuickBEAM.JS.Parser.Diagnostics.StrictCallAssignmentTargetTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects call expressions as strict assignment and update targets" do
    for source <- [
          ~S|"use strict"; f() = 1;|,
          ~S|"use strict"; f() += 1;|,
          ~S|"use strict"; f()++;|,
          ~S|"use strict"; ++f();|
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid assignment target"))
    end
  end

  test "rejects call expressions as strict for-in and for-of targets" do
    for source <- [
          ~S|"use strict"; for (f() in object) {}|,
          ~S|"use strict"; for (f() of object) {}|
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid assignment target"))
    end
  end

  test "preserves sloppy Annex B call expression targets" do
    for source <- ["f() = 1;", "f()++;", "for (f() in object) {}"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
