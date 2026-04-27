defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleNestedStrictBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module nested eval binding strict diagnostics" do
    source = "if (enabled) { let eval = value; }"

    assert {:error, %AST.Program{source_type: :module, body: [%AST.IfStatement{}]}, errors} =
             Parser.parse(source, source_type: :module)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
