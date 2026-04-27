defmodule QuickBEAM.JS.Parser.Diagnostics.AsyncGeneratorYieldParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS async generator object method yield parameter diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("object = { async *method({ yield }) {} };")

    assert Enum.any?(errors, &(&1.message == "yield parameter not allowed in generator function"))
  end

  test "ports QuickJS async generator class method yield parameter diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} =
             Parser.parse("class C { async *method({ yield }) {} }")

    assert Enum.any?(errors, &(&1.message == "yield parameter not allowed in generator function"))
  end
end
