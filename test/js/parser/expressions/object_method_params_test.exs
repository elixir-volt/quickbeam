defmodule QuickBEAM.JS.Parser.Expressions.ObjectMethodParamsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects duplicate object method parameters" do
    for source <- ["({ method(a, a) {} });", "({ async method(a, a) {} });"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "duplicate parameter name not allowed in strict mode")
             )
    end
  end

  test "rejects super calls in regular and generator object method parameters" do
    for source <- ["({ method(x = super()) {} });", "({ *method(x = super()) {} });"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "super not allowed outside class method"))
    end
  end

  test "allows super properties in object method parameters" do
    for source <- [
          "({ method(x = super.value) {} });",
          "({ *method(x = super.value) {} });",
          "({ async method(x = super.value) {} });"
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end

  test "rejects direct super calls in async object method parameters" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("({ async method(x = super()) {} });")
    assert Enum.any?(errors, &(&1.message == "super not allowed outside class method"))
  end

  test "rejects await in async object method parameter defaults" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("({ async method(x = await) {} });")
    assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
  end
end
