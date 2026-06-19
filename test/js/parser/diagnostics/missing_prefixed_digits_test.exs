defmodule QuickBEAM.JS.Parser.Diagnostics.MissingPrefixedDigitsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS missing prefixed numeric literal diagnostics" do
    for source <- ["value = 0x;", "value = 0b;", "value = 0o;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid number literal"))
    end
  end
end
