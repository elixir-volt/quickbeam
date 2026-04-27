defmodule QuickBEAM.JS.Parser.Diagnostics.DuplicatePrivateAccessorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS duplicate private getter diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} =
             Parser.parse("class C { get #value() {} get #value() {} }")

    assert Enum.any?(errors, &(&1.message == "duplicate private name"))
  end

  test "ports QuickJS private getter setter pair syntax" do
    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: [getter, setter]}]}} =
             Parser.parse("class C { get #value() {} set #value(value) {} }")

    assert %AST.MethodDefinition{key: %AST.PrivateIdentifier{name: "value"}, kind: :get} = getter
    assert %AST.MethodDefinition{key: %AST.PrivateIdentifier{name: "value"}, kind: :set} = setter
  end
end
