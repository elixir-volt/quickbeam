defmodule QuickBEAM.JS.Parser.Diagnostics.GeneratorYieldParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS generator yield parameter diagnostics" do
    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{generator: true}]}, errors} =
             Parser.parse("function *g(yield) {}")

    assert Enum.any?(errors, &(&1.message == "yield parameter not allowed in generator function"))
  end
end
