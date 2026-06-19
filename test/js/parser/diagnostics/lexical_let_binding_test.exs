defmodule QuickBEAM.JS.Parser.Diagnostics.LexicalLetBindingTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects lexical declarations binding let" do
    for source <- [
          "let let = 1;",
          "const\nlet = 1;",
          "const { let } = value;",
          "for (let let in obj) {}",
          "for (const let of obj) {}"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "lexical declaration cannot bind let"))
    end
  end
end
