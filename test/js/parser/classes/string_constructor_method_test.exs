defmodule QuickBEAM.JS.Parser.Classes.StringConstructorMethodTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows string and computed constructor method names" do
    for source <- [
          "class C { \"constructor\"() {} }",
          "class C { [\"constructor\"]() {} }"
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
