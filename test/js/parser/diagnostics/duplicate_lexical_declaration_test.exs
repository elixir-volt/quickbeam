defmodule QuickBEAM.JS.Parser.Diagnostics.DuplicateLexicalDeclarationTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS duplicate let declaration diagnostics" do
    assert {:error, %AST.Program{body: [%AST.VariableDeclaration{}, %AST.VariableDeclaration{}]},
            errors} =
             Parser.parse("let value; let value;")

    assert Enum.any?(errors, &(&1.message == "duplicate lexical declaration"))
  end

  test "ports QuickJS duplicate const and class declaration diagnostics" do
    assert {:error, %AST.Program{body: [%AST.VariableDeclaration{}, %AST.ClassDeclaration{}]},
            errors} =
             Parser.parse("const C = 1; class C {}")

    assert Enum.any?(errors, &(&1.message == "duplicate lexical declaration"))
  end
end
