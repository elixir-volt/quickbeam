defmodule QuickBEAM.JS.Parser.ControlFlow.IfAnnexBFunctionTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows sloppy function declarations in if statement bodies" do
    for source <- ["if (flag) function f() {}", "if (flag) ; else function f() {}"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "rejects async and generator declarations in if statement bodies" do
    for source <- [
          "if (flag) async function f() {}",
          "if (flag) function* f() {}",
          "if (flag) ; else async function* f() {}"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "function declarations can't appear in single-statement context")
             )
    end
  end
end
