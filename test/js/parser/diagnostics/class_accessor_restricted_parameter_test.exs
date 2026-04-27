defmodule QuickBEAM.JS.Parser.Diagnostics.ClassAccessorRestrictedParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS class accessor restricted parameter diagnostics" do
    source = "class C { set value(eval) { this.value = eval; } }"

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "restricted parameter name in strict mode"))
  end
end
