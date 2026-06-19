defmodule QuickBEAM.JS.Parser.Diagnostics.ReservedIdentifierEdgesTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects enum bindings" do
    for source <- ["var enum = 1;", "var \\u{65}num = 1;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message in ["expected binding identifier", "escaped reserved word"])
             )
    end
  end

  test "rejects vertical tilde as identifier start" do
    for source <- ["var ⸯ;", "var \\u2E2F;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert errors != []
    end
  end

  test "rejects escaped reserved literal words" do
    for source <- ["tru\\u{65};", "fals\\u{65};", "n\\u{75}ll;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "escaped reserved word"))
    end
  end

  test "rejects reserved shorthand this" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("({this});")
    assert Enum.any?(errors, &(&1.message == "invalid object initializer"))
  end
end
