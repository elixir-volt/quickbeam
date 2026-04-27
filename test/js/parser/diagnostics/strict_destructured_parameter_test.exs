defmodule QuickBEAM.JS.Parser.Diagnostics.StrictDestructuredParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict destructured parameter diagnostics" do
    source = ~S|function f({ eval: renamed }, [arguments]) { "use strict"; }|

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "restricted parameter name in strict mode"))
  end
end
