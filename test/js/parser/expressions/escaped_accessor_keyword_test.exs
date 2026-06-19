defmodule QuickBEAM.JS.Parser.Expressions.EscapedAccessorKeywordTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects escaped get and set contextual keywords in object accessors" do
    for source <- ["({ \\u0067et m() {} });", "({ \\u0073et m(v) {} });"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert errors != []
    end
  end

  test "allows unescaped get and set contextual keywords in object accessors" do
    assert {:ok, %AST.Program{}} = Parser.parse("({ get m() {}, set m(v) {} });")
  end
end
