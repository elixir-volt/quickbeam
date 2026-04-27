defmodule QuickBEAM.JS.Parser.Diagnostics.LexicalVarConflictTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS lexical declaration conflict with var diagnostics" do
    assert {:error, %AST.Program{body: [%AST.VariableDeclaration{}, %AST.VariableDeclaration{}]},
            errors} =
             Parser.parse("var value; let value;")

    assert Enum.any?(
             errors,
             &(&1.message == "lexical declaration conflicts with var declaration")
           )
  end

  test "ports QuickJS lexical declaration conflict with function diagnostics" do
    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{}, %AST.VariableDeclaration{}]},
            errors} =
             Parser.parse("function value() {} const value = 1;")

    assert Enum.any?(
             errors,
             &(&1.message == "lexical declaration conflicts with var declaration")
           )
  end
end
