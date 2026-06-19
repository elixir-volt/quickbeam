defmodule QuickBEAM.JS.Parser.Diagnostics.BlockFunctionRedeclarationTest do
  use ExUnit.Case, async: true
  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects duplicate block function lexical conflicts" do
    for source <- ["{ async function f() {} function f() {} }", "{ function f() {} class f {} }"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "duplicate lexical declaration"))
    end
  end

  test "preserves sloppy duplicate plain block function declarations" do
    assert {:ok, %AST.Program{}} = Parser.parse("{ function f() {} function f() {} }")
  end

  test "rejects block function var conflicts" do
    for source <- ["{ function f() {} var f; }", "{ { var f; } function f() {} }"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "lexical declaration conflicts with var declaration")
             )
    end
  end

  test "preserves top-level function and var redeclaration" do
    assert {:ok, %AST.Program{}} = Parser.parse("function f() {} var f;")
  end
end
