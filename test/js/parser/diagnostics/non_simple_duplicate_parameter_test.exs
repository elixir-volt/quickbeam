defmodule QuickBEAM.JS.Parser.Diagnostics.NonSimpleDuplicateParameterTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects duplicate names with default parameters" do
    for source <- [
          "value = async function (a, a = 1) {};",
          "value = async function *(a, a = 1) {};"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "duplicate parameter name not allowed in strict mode")
             )
    end
  end

  test "preserves duplicate simple sloppy function params" do
    assert {:ok, %AST.Program{}} = Parser.parse("value = function (a, a) {};")
  end
end
