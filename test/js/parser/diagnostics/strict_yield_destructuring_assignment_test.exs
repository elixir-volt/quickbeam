defmodule QuickBEAM.JS.Parser.Diagnostics.StrictYieldDestructuringAssignmentTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects yield references inside strict destructuring assignment targets" do
    for source <- [
          ~S|"use strict"; [...x[yield]] = [];|,
          ~S|"use strict"; ({p: x[yield]} = {});|,
          ~S|"use strict"; [x = yield] = [];|
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "yield expression not within generator"))
    end
  end
end
