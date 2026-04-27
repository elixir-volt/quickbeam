defmodule QuickBEAM.JS.Parser.Diagnostics.DuplicatePrivateNameTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS duplicate private field diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} =
             Parser.parse("class C { #value; #value; }")

    assert Enum.any?(errors, &(&1.message == "duplicate private name"))
  end

  test "ports QuickJS duplicate private method diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} =
             Parser.parse("class C { #value() {} #value() {} }")

    assert Enum.any?(errors, &(&1.message == "duplicate private name"))
  end
end
