defmodule QuickBEAM.JS.Parser.Diagnostics.StrictRestParameterNameTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict rest parameter name diagnostics" do
    source = ~S|function f(...arguments) { "use strict"; }|

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "restricted parameter name in strict mode"))
  end
end
