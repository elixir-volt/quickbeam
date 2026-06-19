defmodule QuickBEAM.JS.Parser.Diagnostics.PrivateNameOutsideClassTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS private member outside class diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("object.#missing;")

    assert Enum.any?(errors, &(&1.message == "undeclared private name"))
  end

  test "ports QuickJS private in-expression outside class diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("#missing in object;")

    assert Enum.any?(errors, &(&1.message == "undeclared private name"))
  end
end
