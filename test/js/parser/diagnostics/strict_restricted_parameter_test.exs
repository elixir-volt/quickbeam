defmodule QuickBEAM.JS.Parser.Diagnostics.StrictRestrictedParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict restricted parameter diagnostics" do
    for source <- [
          ~S|function f(eval) { "use strict"; }|,
          ~S|function g(arguments) { "use strict"; }|
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "restricted parameter name in strict mode"))
    end
  end
end
