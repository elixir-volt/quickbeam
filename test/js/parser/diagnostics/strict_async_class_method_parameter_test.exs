defmodule QuickBEAM.JS.Parser.Diagnostics.StrictAsyncClassMethodParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict async class method parameter diagnostics" do
    source = ~S|class C { async method(a, a) { "use strict"; return a; } }|

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)

    assert Enum.any?(
             errors,
             &(&1.message == "duplicate parameter name not allowed in strict mode")
           )
  end
end
