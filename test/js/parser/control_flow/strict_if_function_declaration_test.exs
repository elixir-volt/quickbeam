defmodule QuickBEAM.JS.Parser.ControlFlow.StrictIfFunctionDeclarationTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects function declarations as if branches in strict scripts" do
    for source <- [
          ~S|"use strict"; if (ok) function f() {}|,
          ~S|"use strict"; if (ok) ; else async function f() {}|,
          ~S|"use strict"; if (ok) function* f() {} else ;|
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "function declarations can't appear in single-statement context")
             )
    end
  end

  test "continues allowing plain function declarations as if branches in sloppy scripts" do
    assert {:ok, %AST.Program{}} =
             Parser.parse("if (ok) function f() {} else function g() {}")
  end
end
