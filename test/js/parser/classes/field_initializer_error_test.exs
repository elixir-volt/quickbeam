defmodule QuickBEAM.JS.Parser.Classes.FieldInitializerErrorTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects super calls inside class field arrow initializers" do
    source = "var C = class { x = () => super(); }"

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)

    assert Enum.any?(
             errors,
             &(&1.message == "super call not allowed outside derived constructor")
           )
  end

  test "rejects arguments inside class field arrow initializers" do
    source = "var C = class { x = () => arguments; }"

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)

    assert Enum.any?(
             errors,
             &(&1.message == "arguments is not allowed in class field initializer")
           )
  end
end
