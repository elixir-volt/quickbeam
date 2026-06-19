defmodule QuickBEAM.JS.Parser.Classes.AsyncMethodSuperParameterTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows super calls in async class method parameter defaults" do
    source =
      "class Base { async method() {} } class Derived extends Base { async method(x = super.method()) {} }"

    assert {:ok, %AST.Program{}} = Parser.parse(source)
  end
end
