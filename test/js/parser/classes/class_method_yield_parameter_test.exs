defmodule QuickBEAM.JS.Parser.Classes.ClassMethodYieldParameterTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects yield in class method parameter initializers" do
    for source <- ["class C { m(x = yield) {} }", "class C { static m(x = yield) {} }"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "yield parameter not allowed in generator function")
             )
    end
  end
end
