defmodule QuickBEAM.JS.Parser.Diagnostics.ClassElementSuperCallTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS static block super call diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} =
             Parser.parse("class C extends B { static { super(); } }")

    assert Enum.any?(
             errors,
             &(&1.message == "super call not allowed outside derived constructor")
           )
  end

  test "ports QuickJS field initializer super call diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} =
             Parser.parse("class C extends B { field = super(); }")

    assert Enum.any?(
             errors,
             &(&1.message == "super call not allowed outside derived constructor")
           )
  end
end
