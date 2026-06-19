defmodule QuickBEAM.JS.Parser.Diagnostics.StrictAsyncArrowParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict async arrow parameter diagnostics" do
    source = ~S|value = async (eval) => { "use strict"; return eval; };|

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "restricted parameter name in strict mode"))
  end
end
