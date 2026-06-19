defmodule QuickBEAM.JS.Parser.Diagnostics.FunctionDeclarationStatementPositionTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS function declaration single-statement diagnostics" do
    for source <- [
          "while (false) function g() {}",
          "do function g() {} while (false)",
          "for (;;) function g() {}"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "function declarations can't appear in single-statement context")
             )
    end
  end

  test "preserves function declarations in blocks" do
    assert {:ok, %AST.Program{}} = Parser.parse("while (false) { function g() {} }")
  end
end
