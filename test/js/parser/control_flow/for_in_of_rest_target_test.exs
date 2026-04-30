defmodule QuickBEAM.JS.Parser.ControlFlow.ForInOfRestTargetTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects invalid rest positions and initializers in for-in/of destructuring heads" do
    for source <- [
          "for ([...x, y] of [[]]);",
          "for ([...x,] in obj);",
          "for ([...x = 1] of [[]]);",
          "for ({...rest, b} of [{}]);"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid destructuring target"))
    end
  end
end
