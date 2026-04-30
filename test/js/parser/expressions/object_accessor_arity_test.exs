defmodule QuickBEAM.JS.Parser.Expressions.ObjectAccessorArityTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "validates object accessor arity" do
    for source <- [
          "({ get value(param = null) {} });",
          "({ set value() {} });",
          "({ set value(a, b) {} });"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "invalid number of arguments for getter or setter")
             )
    end
  end

  test "allows valid object accessors" do
    assert {:ok, %AST.Program{}} = Parser.parse("({ get value() {}, set value(v) {} });")
  end
end
