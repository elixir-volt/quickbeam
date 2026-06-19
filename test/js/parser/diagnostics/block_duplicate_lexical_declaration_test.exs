defmodule QuickBEAM.JS.Parser.Diagnostics.BlockDuplicateLexicalDeclarationTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS duplicate lexical declarations in block diagnostics" do
    assert {:error, %AST.Program{body: [%AST.BlockStatement{}]}, errors} =
             Parser.parse("{ let value; const value = 1; }")

    assert Enum.any?(errors, &(&1.message == "duplicate lexical declaration"))
  end

  test "ports QuickJS duplicate lexical declarations in function body diagnostics" do
    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{}]}, errors} =
             Parser.parse("function f() { let value; let value; }")

    assert Enum.any?(errors, &(&1.message == "duplicate lexical declaration"))
  end
end
