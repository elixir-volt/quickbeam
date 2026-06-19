defmodule QuickBEAM.JS.Parser.Diagnostics.SemicolonInsertionTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS missing semicolon diagnostics between expressions" do
    for source <- ["{ 1 2 } 3", "{1 2} 3"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "expected ;"))
    end
  end

  test "ports QuickJS missing semicolon diagnostics before else" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("if (false) x = 1 else x = -1")
    assert Enum.any?(errors, &(&1.message == "expected ;"))
  end
end
