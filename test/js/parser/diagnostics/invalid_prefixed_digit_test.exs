defmodule QuickBEAM.JS.Parser.Diagnostics.InvalidPrefixedDigitTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS invalid prefixed numeric digit diagnostics" do
    for source <- ["value = 0b2;", "value = 0o8;", "value = 0xg;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid number literal"))
    end
  end
end
