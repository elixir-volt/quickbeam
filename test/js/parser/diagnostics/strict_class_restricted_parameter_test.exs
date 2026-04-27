defmodule QuickBEAM.JS.Parser.Diagnostics.StrictClassRestrictedParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict class restricted parameter diagnostics" do
    for source <- [
          ~S|class C { method(eval) { "use strict"; } }|,
          ~S|class C { method(arguments) { "use strict"; } }|
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "restricted parameter name in strict mode"))
    end
  end
end
