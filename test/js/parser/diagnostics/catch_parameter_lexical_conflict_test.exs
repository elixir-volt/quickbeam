defmodule QuickBEAM.JS.Parser.Diagnostics.CatchParameterLexicalConflictTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS catch parameter lexical conflict diagnostics" do
    assert {:error, %AST.Program{body: [%AST.TryStatement{}]}, errors} =
             Parser.parse("try {} catch (error) { let error; }")

    assert Enum.any?(
             errors,
             &(&1.message == "catch parameter conflicts with lexical declaration")
           )
  end

  test "ports QuickJS destructured catch parameter lexical conflict diagnostics" do
    assert {:error, %AST.Program{body: [%AST.TryStatement{}]}, errors} =
             Parser.parse("try {} catch ({ error }) { const error = 1; }")

    assert Enum.any?(
             errors,
             &(&1.message == "catch parameter conflicts with lexical declaration")
           )
  end
end
