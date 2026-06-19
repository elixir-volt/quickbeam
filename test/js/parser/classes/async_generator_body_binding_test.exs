defmodule QuickBEAM.JS.Parser.Classes.AsyncGeneratorBodyBindingTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects await bindings and labels in async method bodies" do
    for source <- [
          "class C { async m() { var await; } }",
          "class C { async m() { await: statement; } }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
    end
  end

  test "rejects yield bindings and labels in async generator method bodies" do
    for source <- [
          "class C { async *m() { var yield; } }",
          "class C { async *m() { yield: statement; } }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "yield parameter not allowed in generator function")
             )
    end
  end
end
