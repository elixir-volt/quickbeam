defmodule QuickBEAM.JS.Parser.Diagnostics.BlockLexicalVarConflictTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS block lexical declaration conflict with var diagnostics" do
    assert {:error, %AST.Program{body: [%AST.BlockStatement{}]}, errors} =
             Parser.parse("{ let value; var value; }")

    assert Enum.any?(
             errors,
             &(&1.message == "lexical declaration conflicts with var declaration")
           )
  end

  test "ports QuickJS function body lexical declaration conflict with var diagnostics" do
    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{}]}, errors} =
             Parser.parse("function f() { const value = 1; var value; }")

    assert Enum.any?(
             errors,
             &(&1.message == "lexical declaration conflicts with var declaration")
           )
  end
end
