defmodule QuickBEAM.JS.Parser.ControlFlow.ForInOfHeadTargetTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects invalid for-in/of assignment targets" do
    for source <- ["for (this of []) {}", "for ((this) in obj) {}"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid assignment target"))
    end
  end

  test "rejects escaped of in for-of heads" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("for (var x o\\u0066 []) ;")
    assert errors != []
  end
end
