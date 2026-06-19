defmodule QuickBEAM.JS.Parser.Diagnostics.RestrictedGlobalLexicalTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects global lexical undefined in scripts" do
    for source <- ["let undefined;", "const undefined = 1;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "restricted global lexical binding"))
    end
  end
end
