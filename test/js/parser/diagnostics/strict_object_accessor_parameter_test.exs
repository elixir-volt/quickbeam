defmodule QuickBEAM.JS.Parser.Diagnostics.StrictObjectAccessorParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict object accessor parameter diagnostics" do
    source = ~S|object = { set value(eval) { "use strict"; this.value = eval; } };|

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "restricted parameter name in strict mode"))
  end
end
