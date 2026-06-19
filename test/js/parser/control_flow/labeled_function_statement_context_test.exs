defmodule QuickBEAM.JS.Parser.ControlFlow.LabeledFunctionStatementContextTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects labeled function declarations in single-statement contexts" do
    for source <- [
          "while (x) label: function f() {}",
          "if (x) label: function f() {}",
          "for (;;) label: function f() {}",
          "with (x) label: function f() {}",
          "do label: function f() {} while (x);"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "function declarations can't appear in single-statement context")
             )
    end
  end
end
