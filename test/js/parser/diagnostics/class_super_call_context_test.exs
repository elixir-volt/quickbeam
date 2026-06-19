defmodule QuickBEAM.JS.Parser.Diagnostics.ClassSuperCallContextTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS base class constructor super call diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} =
             Parser.parse("class C { constructor() { super(); } }")

    assert Enum.any?(
             errors,
             &(&1.message == "super call not allowed outside derived constructor")
           )
  end

  test "ports QuickJS class method super call diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} =
             Parser.parse("class C extends B { method() { super(); } }")

    assert Enum.any?(
             errors,
             &(&1.message == "super call not allowed outside derived constructor")
           )
  end
end
