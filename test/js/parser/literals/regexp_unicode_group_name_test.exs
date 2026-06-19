defmodule QuickBEAM.JS.Parser.Literals.RegexpUnicodeGroupNameTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows unicode and escaped unicode regexp group names" do
    for source <- [
          ~S|/(?<𝓓𝓸𝓰>dog)\k<𝓓𝓸𝓰>/u;|,
          ~S|/(?<π>a)/u;|,
          ~S|/(?<ಠ_ಠ>a)/u;|,
          ~S|/(?<狸>fox).*(?<狗>dog)/u;|,
          ~S|/(?<a\uD801\uDCA4>.)/u;|,
          ~S|/(?<a\u{104A4}>.)/u;|,
          ~S|/(?<\u{1d5b0}\u{1d5a1}\u{1d5a5}>qbf)/u;|
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "allows quantified atoms inside lookbehind assertions" do
    for source <- [~S|/(?<=(\w){3})def/;|, ~S|/(?<=((?:b\d{2})+))c/;|] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
