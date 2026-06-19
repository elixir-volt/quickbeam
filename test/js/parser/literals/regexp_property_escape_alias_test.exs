defmodule QuickBEAM.JS.Parser.Literals.RegexpPropertyEscapeAliasTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "accepts Unknown unicode script aliases" do
    for source <- [
          ~S(pattern = /\p{Script=Unknown}/u;),
          ~S(pattern = /\p{scx=Unknown}/u;),
          ~S(pattern = /\p{Script=Zzzz}/u;),
          ~S(pattern = /\p{scx=Zzzz}/u;)
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "ports QuickJS unknown unicode property names" do
    for source <- [~S(pattern = /\p{RGI_Emoji}/u;), ~S(pattern = /\p{InGreek}/u;)] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "unknown unicode property name"))
    end
  end

  test "preserves v-flag unicode string properties" do
    for source <- [~S(pattern = /\p{RGI_Emoji}/v;), ~S(pattern = /\p{Emoji_Keycap_Sequence}/v;)] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "preserves valid aliases from vendored QuickJS unicode tables" do
    for source <- [
          ~S(pattern = /\p{Script=Greek}/u;),
          ~S(pattern = /\p{Script=Grek}/u;),
          ~S(pattern = /\p{gc=Lu}/u;),
          ~S(pattern = /\p{Alpha}/u;)
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
