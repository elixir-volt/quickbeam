defmodule QuickBEAM.JS.Parser.Diagnostics.RestInitializerTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS array rest initializer diagnostics" do
    assert {:error, %AST.Program{body: [%AST.VariableDeclaration{} | _]}, errors} =
             Parser.parse("var [...rest = value] = array;")

    assert Enum.any?(errors, &(&1.message == "rest element cannot have initializer"))
  end

  test "ports QuickJS object rest initializer diagnostics" do
    assert {:error, %AST.Program{body: [%AST.VariableDeclaration{}]}, errors} =
             Parser.parse("var { ...rest = value } = object;")

    assert Enum.any?(errors, &(&1.message == "rest element cannot have initializer"))
  end

  test "ports QuickJS rest parameter initializer diagnostics" do
    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{}]}, errors} =
             Parser.parse("function f(...rest = value) {}")

    assert Enum.any?(errors, &(&1.message == "rest element cannot have initializer"))
  end
end
