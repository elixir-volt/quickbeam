defmodule QuickBEAM.JS.Parser.Classes.PrivateSuperAccessTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects private member access on super" do
    for source <- [
          "class C extends B { #x() {} method() { super.#x(); } }",
          "var C = class { Child = class extends B { method() { return super.#x; } } };"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "private class field forbidden after super"))
    end
  end

  test "rejects undeclared private names in computed class keys" do
    assert {:error, %AST.Program{}, errors} =
             Parser.parse("var C = class { [this.#f] = 'value'; };")

    assert Enum.any?(errors, &(&1.message == "undeclared private name"))
  end
end
