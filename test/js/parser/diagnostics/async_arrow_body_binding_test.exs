defmodule QuickBEAM.JS.Parser.Diagnostics.AsyncArrowBodyBindingTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects await bindings in async arrow bodies" do
    for source <- ["async () => { var await; }", "async () => { var aw\\u0061it; }"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
    end
  end

  test "rejects await and yield async generator function names" do
    for source <- ["value = async function *await() {};", "value = async function *yield() {};"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message in [
                   "await parameter not allowed in async function",
                   "yield parameter not allowed in generator function"
                 ])
             )
    end
  end
end
