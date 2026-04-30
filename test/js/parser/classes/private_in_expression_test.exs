defmodule QuickBEAM.JS.Parser.Classes.PrivateInExpressionTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects invalid private-in expression forms" do
    for source <- [
          "class C { #field; m() { #field in #field in this; } }",
          "class C { #field; m() { #field in () => {}; } }",
          "class C { #field; m() { for (#field in []) ; } }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid private in expression"))
    end
  end

  test "ports QuickJS-compatible private-in expression syntax" do
    assert {:ok, %AST.Program{}} = Parser.parse("class C { #field; m() { #field in this; } }")
  end
end
