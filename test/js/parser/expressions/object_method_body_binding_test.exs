defmodule QuickBEAM.JS.Parser.Expressions.ObjectMethodBodyBindingTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects yield bindings in generator object method bodies" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("({ *method() { var yield; } });")
    assert Enum.any?(errors, &(&1.message == "yield parameter not allowed in generator function"))
  end

  test "rejects await bindings in async object method bodies" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("({ async method() { var await; } });")
    assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
  end
end
