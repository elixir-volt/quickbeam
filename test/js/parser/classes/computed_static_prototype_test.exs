defmodule QuickBEAM.JS.Parser.Classes.ComputedStaticPrototypeTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows computed static prototype accessors" do
    for source <- [
          "class C { static get ['prototype']() {} }",
          "class C { static set ['prototype'](value) {} }"
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "keeps non-computed static prototype methods invalid" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("class C { static prototype() {} }")
    assert Enum.any?(errors, &(&1.message == "invalid method name"))
  end
end
