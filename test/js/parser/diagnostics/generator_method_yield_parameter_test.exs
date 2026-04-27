defmodule QuickBEAM.JS.Parser.Diagnostics.GeneratorMethodYieldParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS generator object method yield parameter diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("object = { *method({ yield }) {} };")

    assert Enum.any?(errors, &(&1.message == "yield parameter not allowed in generator function"))
  end

  test "ports QuickJS generator class method yield parameter diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} =
             Parser.parse("class C { *method({ yield }) {} }")

    assert Enum.any?(errors, &(&1.message == "yield parameter not allowed in generator function"))
  end
end
