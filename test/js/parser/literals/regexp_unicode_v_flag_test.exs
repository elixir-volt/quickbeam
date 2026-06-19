defmodule QuickBEAM.JS.Parser.Literals.RegexpUnicodeVFlagTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible non-ASCII v-flag regexp literals" do
    for source <- ["pattern = /𠮷/v;", "pattern = /[👨‍👩‍👧‍👦]/v;"] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
