defmodule QuickBEAM.JS.Parser.Classes.PrivateDeleteTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects delete of private members in class fields and methods" do
    for source <- [
          "var C = class { #x; x = delete this.#x; }",
          "class C { #x; method() { delete this.#x; } }",
          "class C { #x; method() { delete this.#x(); } }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "cannot delete a private class field"))
    end
  end

  test "allows ordinary delete in class elements" do
    assert {:ok, %AST.Program{}} = Parser.parse("class C { method() { delete this.x; } }")
  end
end
