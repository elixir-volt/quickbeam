defmodule QuickBEAM.JS.Parser.Diagnostics.ArrowParameterContextTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects await arrow parameter in class static block" do
    source = "class C { static { (await => 0); } }"

    assert {:error, %AST.Program{}, _errors} = Parser.parse(source)
  end

  test "rejects yield expression in generator arrow parameter initializer" do
    source = "function *g() { (x = yield) => {}; }"

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "yield parameter not allowed in generator function"))
  end
end
