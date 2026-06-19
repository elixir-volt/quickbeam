defmodule QuickBEAM.JS.Parser.Diagnostics.StrictObjectMethodBodyBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict object method body binding diagnostics" do
    source = ~S|object = { method() { "use strict"; var eval; } };|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
