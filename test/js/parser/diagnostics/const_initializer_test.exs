defmodule QuickBEAM.JS.Parser.Diagnostics.ConstInitializerTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible const initializer syntax error" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("const value;")
    assert Enum.any?(errors, &(&1.message == "missing initializer in const declaration"))
  end

  test "ports QuickJS-compatible const declaration initializer syntax" do
    assert {:ok, %AST.Program{body: [%AST.VariableDeclaration{kind: :const}]}} =
             Parser.parse("const value = 1;")
  end
end
