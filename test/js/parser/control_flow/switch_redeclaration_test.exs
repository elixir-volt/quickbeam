defmodule QuickBEAM.JS.Parser.ControlFlow.SwitchRedeclarationTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects lexical redeclarations across switch clauses" do
    for source <- [
          "switch (x) { case 0: let y; case 1: const y = 1; }",
          "switch (x) { case 0: class Y {} case 1: let Y; }",
          "switch (x) { case 0: function y() {} case 1: const y = 1; }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert errors != []
    end
  end

  test "allows sloppy duplicate function declarations across switch clauses" do
    assert {:ok, %AST.Program{}} =
             Parser.parse("switch (x) { case 0: function y() {} case 1: function y() {} }")
  end

  test "rejects var declarations conflicting with switch lexical declarations" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse("switch (x) { case 0: let y; case 1: var y; }")

    assert errors != []
  end
end
