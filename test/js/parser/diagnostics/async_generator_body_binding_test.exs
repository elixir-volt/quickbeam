defmodule QuickBEAM.JS.Parser.Diagnostics.AsyncGeneratorBodyBindingTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects await bindings and labels in async function bodies" do
    for source <- [
          "value = async function () { var await; };",
          "value = async function () { await: statement; };"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
    end
  end

  test "rejects yield bindings and labels in async generator bodies" do
    for source <- [
          "value = async function *() { var yield; };",
          "value = async function *() { yield: statement; };"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "yield parameter not allowed in generator function")
             )
    end
  end
end
