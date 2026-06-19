defmodule QuickBEAM.JS.Parser.Classes.PrivateNameValidationTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects undeclared private names in class expressions" do
    for source <- [
          "var C = class { method() { this.#x; } };",
          "var C = class extends this.#x {};"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "undeclared private name"))
    end
  end

  test "rejects duplicate private names in class expressions" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("var C = class { #x; #x; };")
    assert Enum.any?(errors, &(&1.message == "duplicate private name"))
  end
end
