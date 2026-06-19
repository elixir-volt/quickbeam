defmodule QuickBEAM.JS.Parser.ControlFlow.LetExpressionStatementASITest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "treats let followed by a line terminator as an expression statement in scripts" do
    for source <- [
          "for (var x of []) let\nx = 1;",
          "for (var x of []) let\n{}",
          "for (var x in y) let\nx = 1;"
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "keeps let followed by a line-terminated array or object as a lexical declaration" do
    for source <- ["for (var x of []) let\n[a] = 0;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "lexical declarations can't appear in single-statement context")
             )
    end
  end
end
