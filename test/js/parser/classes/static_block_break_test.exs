defmodule QuickBEAM.JS.Parser.Classes.StaticBlockBreakTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects unlabeled break in static blocks" do
    for source <- [
          "class A { static { break; } }",
          "label: while(false) { class A { static { break; } } }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "break statement not within loop or switch"))
    end
  end
end
