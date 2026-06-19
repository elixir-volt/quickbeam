defmodule QuickBEAM.JS.Parser.Diagnostics.UndeclaredPrivateNameTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS undeclared private member diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} =
             Parser.parse("class C { method() { return this.#missing; } }")

    assert Enum.any?(errors, &(&1.message == "undeclared private name"))
  end

  test "ports QuickJS undeclared private in-expression diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} =
             Parser.parse("class C { method() { return #missing in this; } }")

    assert Enum.any?(errors, &(&1.message == "undeclared private name"))
  end
end
