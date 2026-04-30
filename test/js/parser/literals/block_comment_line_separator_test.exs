defmodule QuickBEAM.JS.Parser.Literals.BlockCommentLineSeparatorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS ASI after block comments with unicode line separators" do
    for separator <- [<<0x2028::utf8>>, <<0x2029::utf8>>] do
      source = ~s|''/*#{separator}*/''|
      assert {:ok, %AST.Program{body: statements}} = Parser.parse(source)
      assert length(statements) == 2
    end
  end
end
