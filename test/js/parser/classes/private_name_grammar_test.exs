defmodule QuickBEAM.JS.Parser.Classes.PrivateNameGrammarTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects whitespace between private marker and name" do
    for source <- [
          "var C = class { # x; };",
          "var C = class { method() { this.# x; } };",
          "var C = class { method() { this.# x(); } };"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert errors != []
    end
  end

  test "rejects ZWNJ and ZWJ as private name starts" do
    for source <- ["var C = class { #\\u200C_ZWNJ; };", "var C = class { #\\u200D_ZWJ; };"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert errors != []
    end
  end
end
