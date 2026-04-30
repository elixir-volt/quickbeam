defmodule QuickBEAM.JS.Parser.ControlFlow.CatchBindingConflictTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects duplicate catch binding names" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("try {} catch ([x, x]) {}")
    assert errors != []
  end

  test "rejects catch parameter conflicts with directly nested function declarations" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("try {} catch (e) { function e() {} }")
    assert errors != []
  end
end
