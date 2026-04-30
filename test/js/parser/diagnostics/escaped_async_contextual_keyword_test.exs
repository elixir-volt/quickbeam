defmodule QuickBEAM.JS.Parser.Diagnostics.EscapedAsyncContextualKeywordTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects escaped async as a contextual async function marker" do
    for source <- ["\\u0061sync function f() {}", "\\u0061sync () => {}"] do
      assert {:error, %AST.Program{}, _errors} = Parser.parse(source)
    end
  end

  test "preserves unescaped async contextual markers" do
    for source <- ["async function f() {}", "async () => {}"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
