defmodule QuickBEAM.JS.Parser.Diagnostics.ArrowLineTerminatorTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects line terminator before parenless arrow" do
    for source <- ["var af = x\n=> {};", "x\n=> x;"] do
      assert {:error, %AST.Program{}, _errors} = Parser.parse(source)
    end
  end

  test "preserves same-line parenless arrow" do
    assert {:ok, %AST.Program{}} = Parser.parse("var af = x => x;")
  end
end
