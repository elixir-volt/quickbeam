defmodule QuickBEAM.JS.Parser.Diagnostics.SuperParameterContextTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects super in function and arrow parameter initializers" do
    for source <- [
          "value = async function (x = super.prop) {};",
          "value = async function (x = super()) {};",
          "value = async (x = super.prop) => x;",
          "value = async (x = super()) => x;"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "super not allowed outside class method"))
    end
  end
end
