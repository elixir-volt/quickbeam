defmodule QuickBEAM.JS.Parser.Diagnostics.ObjectPatternReservedShorthandTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS reserved shorthand object pattern diagnostics" do
    for source <- [~S|var x = ({ bre\u0061k }) => {};|, ~S|var x = ({ default }) => {};|] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "expected binding identifier"))
    end
  end

  test "preserves reserved property names with explicit binding values" do
    assert {:ok, %AST.Program{}} = Parser.parse(~S|var x = ({ default: value }) => value;|)
  end
end
