defmodule QuickBEAM.JS.Parser.Classes.ComputedStaticFieldNameTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows computed static constructor and prototype fields" do
    for source <- [
          "class C { static ['constructor']; }",
          "class C { static ['constructor'] = 42; }",
          "class C { static ['prototype']; }",
          "class C { static ['prototype'] = 42; }"
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "keeps non-computed static prototype and constructor fields invalid" do
    for source <- ["class C { static prototype; }", "class C { static constructor; }"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid field name"))
    end
  end
end
