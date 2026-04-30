defmodule QuickBEAM.JS.Parser.Diagnostics.StrictArrowParameterNamesTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects restricted arrow parameters in strict scripts" do
    for source <- [
          ~S|"use strict"; value = eval => 1;|,
          ~S|"use strict"; value = (arguments) => 1;|
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "restricted parameter name in strict mode"))
    end
  end

  test "rejects yield arrow parameters in strict scripts" do
    assert {:error, %AST.Program{}, errors} = Parser.parse(~S|"use strict"; value = yield => 1;|)
    assert Enum.any?(errors, &(&1.message == "restricted parameter name in strict mode"))
  end
end
