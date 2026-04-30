defmodule QuickBEAM.JS.Parser.Classes.PrivateAccessorStaticPairTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows matching static or instance private getter setter pairs" do
    for source <- [
          "class C { get #f() {} set #f(value) {} }",
          "class C { static get #f() {} static set #f(value) {} }"
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "rejects mixed static private getter setter pairs" do
    for source <- [
          "class C { static get #f() {} set #f(value) {} }",
          "class C { get #f() {} static set #f(value) {} }",
          "class C { static set #f(value) {} get #f() {} }",
          "class C { set #f(value) {} static get #f() {} }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "duplicate private name"))
    end
  end
end
