defmodule QuickBEAM.JS.Parser.ControlFlow.ForHeadLexicalConflictTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects duplicate lexical names in for heads" do
    for source <- [
          "for (let [x, x] in obj) {}",
          "for (const [x, x] of obj) {}"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "duplicate lexical declaration"))
    end
  end

  test "rejects var declarations in for bodies that conflict with lexical head names" do
    for source <- [
          "for (let x; false;) { var x; }",
          "for (let x in obj) { var x; }",
          "for (const x of obj) { var x; }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "lexical declaration conflicts with var declaration")
             )
    end
  end
end
