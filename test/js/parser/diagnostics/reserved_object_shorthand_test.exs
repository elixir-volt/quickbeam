defmodule QuickBEAM.JS.Parser.Diagnostics.ReservedObjectShorthandTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects reserved literal object shorthand names" do
    for source <- ["({ true });", "({ false });", "({ null });"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid object initializer"))
    end
  end
end
