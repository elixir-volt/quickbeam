defmodule QuickBEAM.JS.Parser.ControlFlow.SwitchScopeTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows switch case lexical names to shadow outer block names" do
    assert {:ok, %AST.Program{}} =
             Parser.parse("let x; switch (value) { case 0: let x; }")
  end

  test "rejects duplicate lexical names and var conflicts within switch cases" do
    for source <- [
          "switch (value) { case 0: let x; default: const x = 1; }",
          "switch (value) { case 0: function f() {} default: var f; }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert errors != []
    end
  end

  test "allows sloppy duplicate function declarations within switch cases" do
    assert {:ok, %AST.Program{}} =
             Parser.parse("switch (value) { case 0: function f() {} default: function f() {} }")
  end
end
