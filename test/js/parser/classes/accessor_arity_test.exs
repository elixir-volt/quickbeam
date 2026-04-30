defmodule QuickBEAM.JS.Parser.Classes.AccessorArityTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects class getter parameters" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("class C { get a(param = null) {} }")
    assert Enum.any?(errors, &(&1.message == "invalid number of arguments for getter or setter"))
  end

  test "rejects class setters without exactly one parameter" do
    for source <- ["class C { set a() {} }", "class C { set a(value, extra) {} }"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "invalid number of arguments for getter or setter")
             )
    end
  end
end
