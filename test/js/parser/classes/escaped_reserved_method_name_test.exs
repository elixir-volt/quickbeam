defmodule QuickBEAM.JS.Parser.Classes.EscapedReservedMethodNameTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows escaped reserved words as class method property names" do
    for source <- ["class C { th\\u0069s() {} }", "class C { en\\u0075m() {} }"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
