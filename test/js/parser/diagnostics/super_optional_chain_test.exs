defmodule QuickBEAM.JS.Parser.Diagnostics.SuperOptionalChainTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS super optional member diagnostics" do
    source = "class C extends B { method() { return super?.property; } }"

    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "optional chain not allowed on super"))
  end

  test "ports QuickJS super optional call diagnostics" do
    source = "class C extends B { constructor() { super?.(); } }"

    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "optional chain not allowed on super"))
  end
end
