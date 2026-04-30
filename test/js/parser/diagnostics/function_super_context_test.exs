defmodule QuickBEAM.JS.Parser.Diagnostics.FunctionSuperContextTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects super property in function and arrow expressions outside methods" do
    for source <- [
          "value = async function () { super.prop; };",
          "value = async () => super.prop;",
          "value = async () => { super.prop; };"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "super not allowed outside class method"))
    end
  end

  test "rejects super calls in function and arrow expressions outside constructors" do
    for source <- ["value = async function () { super(); };", "value = async () => super();"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "super not allowed outside class method"))
    end
  end
end
