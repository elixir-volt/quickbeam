defmodule QuickBEAM.JS.Parser.Classes.PrivateNameNestedScopeTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects undeclared private names in nested functions inside class elements" do
    for source <- [
          "var C = class { f = function() { this.#x; } };",
          "var C = class { method() { function f() { this.#x; } } };"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "undeclared private name"))
    end
  end

  test "allows nested classes to access outer private names" do
    source = "var C = class { #outer; Inner = class { method(o) { return o.#outer; } }; };"
    assert {:ok, %AST.Program{}} = Parser.parse(source)
  end
end
