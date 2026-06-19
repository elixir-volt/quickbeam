defmodule QuickBEAM.JS.Parser.Classes.EscapedStaticModifierTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects escaped static as a class method modifier" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("class C { st\\u0061tic m() {} }")
    assert errors != []
  end
end
