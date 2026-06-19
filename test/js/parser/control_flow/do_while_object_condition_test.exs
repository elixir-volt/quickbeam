defmodule QuickBEAM.JS.Parser.ControlFlow.DoWhileObjectConditionTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects invalid object literal forms in do-while conditions" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("do { ; } while ({0});")
    assert Enum.any?(errors, &(&1.message == "invalid object initializer"))
  end
end
