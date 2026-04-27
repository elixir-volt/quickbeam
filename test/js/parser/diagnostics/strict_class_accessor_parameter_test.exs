defmodule QuickBEAM.JS.Parser.Diagnostics.StrictClassAccessorParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict class accessor parameter diagnostics" do
    source = ~S|class C { set value(arguments) { "use strict"; this.value = arguments; } }|

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "restricted parameter name in strict mode"))
  end
end
