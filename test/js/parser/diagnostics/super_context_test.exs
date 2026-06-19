defmodule QuickBEAM.JS.Parser.Diagnostics.SuperContextTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS top-level super call diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("super();")

    assert Enum.any?(errors, &(&1.message == "super not allowed outside class method"))
  end

  test "ports QuickJS function super property diagnostics" do
    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{}]}, errors} =
             Parser.parse("function f() { return super.value; }")

    assert Enum.any?(errors, &(&1.message == "super not allowed outside class method"))
  end
end
