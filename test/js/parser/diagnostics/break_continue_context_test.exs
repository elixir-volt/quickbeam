defmodule QuickBEAM.JS.Parser.Diagnostics.BreakContinueContextTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS break outside loop or switch diagnostics" do
    assert {:error, %AST.Program{body: [%AST.BreakStatement{}]}, errors} = Parser.parse("break;")
    assert Enum.any?(errors, &(&1.message == "break statement not within loop or switch"))
  end

  test "ports QuickJS continue outside loop diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ContinueStatement{}]}, errors} =
             Parser.parse("continue;")

    assert Enum.any?(errors, &(&1.message == "continue statement not within loop"))
  end

  test "ports QuickJS switch continue without loop diagnostics" do
    assert {:error, %AST.Program{body: [%AST.SwitchStatement{}]}, errors} =
             Parser.parse("switch (value) { case 1: continue; }")

    assert Enum.any?(errors, &(&1.message == "continue statement not within loop"))
  end
end
