defmodule QuickBEAM.JS.Parser.Diagnostics.FormalBodyLexicalConflictTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects lexical declarations that conflict with formal parameters" do
    for source <- [
          "async function f(value) { let value; }",
          "value = async function *(value) { const value = 1; };"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "duplicate lexical declaration"))
    end
  end

  test "allows nested block lexical declarations to shadow formal parameters" do
    assert {:ok, %AST.Program{}} = Parser.parse("function f(value) { { class value {} } }")
  end
end
