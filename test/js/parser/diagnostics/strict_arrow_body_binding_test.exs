defmodule QuickBEAM.JS.Parser.Diagnostics.StrictArrowBodyBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict arrow body binding diagnostics" do
    source = ~S|fn = () => { "use strict"; var arguments; };|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
