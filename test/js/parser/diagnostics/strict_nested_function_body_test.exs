defmodule QuickBEAM.JS.Parser.Diagnostics.StrictNestedFunctionBodyTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "treats nested function declarations inside strict functions as strict code" do
    source = ~S|function outer() { "use strict"; function inner() { var static; } }|

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
