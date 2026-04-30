defmodule QuickBEAM.JS.Parser.Classes.ClassElementNameTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects static prototype class elements" do
    for source <- [
          "var C = class { static prototype; };",
          "var C = class { static prototype() {} };"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message in ["invalid field name", "invalid method name"]))
    end
  end

  test "rejects private constructor class elements" do
    for source <- [
          "var C = class { #constructor; };",
          "var C = class { static #constructor() {} };"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message in ["invalid field name", "invalid method name"]))
    end
  end
end
