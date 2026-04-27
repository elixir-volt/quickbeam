defmodule QuickBEAM.JS.Parser.Diagnostics.StrictSwitchBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict switch-case eval binding diagnostics" do
    source = ~S|function f() { "use strict"; switch (value) { case 1: var eval; break; } }|

    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{}]}, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
