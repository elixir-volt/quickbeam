defmodule QuickBEAM.JS.Parser.Classes.ClassReservedNameTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects restricted class binding names" do
    for source <- ["class let {}", "class static {}", "class yield {}", "value = class let {};"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "expected class name"))
    end
  end
end
