defmodule QuickBEAM.JS.Parser.Diagnostics.StrictGeneratorObjectMethodParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict generator object method parameter diagnostics" do
    source = ~S|object = { *method(a, a) { "use strict"; yield a; } };|

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)

    assert Enum.any?(
             errors,
             &(&1.message == "duplicate parameter name not allowed in strict mode")
           )
  end
end
