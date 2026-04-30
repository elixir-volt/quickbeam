defmodule QuickBEAM.JS.Parser.Classes.FieldInitializerNestedErrorTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects super calls nested in class field expressions" do
    for source <- [
          "class C { x = typeof super(); }",
          "class C { x = condition ? value : super(); }",
          "class C { x = (value === super()); }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "super call not allowed outside derived constructor")
             )
    end
  end

  test "rejects arguments nested in class field expressions" do
    for source <- [
          "class C { x = typeof arguments; }",
          "class C { x = condition ? value : arguments; }",
          "class C { x = (value === arguments); }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "arguments is not allowed in class field initializer")
             )
    end
  end
end
