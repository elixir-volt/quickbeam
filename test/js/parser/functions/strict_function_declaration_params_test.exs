defmodule QuickBEAM.JS.Parser.Functions.StrictFunctionDeclarationParamsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects restricted parameter names in function declarations under script strict mode" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("\"use strict\"; function f(eval) {}")
    assert Enum.any?(errors, &(&1.message == "restricted parameter name in strict mode"))
  end
end
