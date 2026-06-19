defmodule QuickBEAM.JS.Parser.Diagnostics.GeneratorYieldParameterInitializerTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects yield expressions in generator parameter initializers" do
    for source <- ["function *g(value = yield) {}", "async function *g(value = yield) {}"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)

      assert Enum.any?(
               errors,
               &(&1.message == "yield parameter not allowed in generator function")
             )
    end
  end
end
