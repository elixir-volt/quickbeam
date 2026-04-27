defmodule QuickBEAM.JS.Parser.Diagnostics.StrictDefaultParameterDuplicateTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict default parameter duplicate diagnostics" do
    source = ~S|function f(a = 1, a = 2) { "use strict"; return a; }|

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)

    assert Enum.any?(
             errors,
             &(&1.message == "duplicate parameter name not allowed in strict mode")
           )
  end
end
