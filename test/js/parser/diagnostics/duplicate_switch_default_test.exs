defmodule QuickBEAM.JS.Parser.Diagnostics.DuplicateSwitchDefaultTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS duplicate switch default diagnostics" do
    source = "switch (value) { default: first(); case 1: one(); default: second(); }"

    assert {:error, %AST.Program{body: [%AST.SwitchStatement{cases: [_first, _case, _second]}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "duplicate default clause"))
  end
end
