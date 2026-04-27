defmodule QuickBEAM.JS.Parser.Diagnostics.ClassGeneratorDuplicateParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS class generator duplicate parameter diagnostics" do
    source = "class C { *method(a, a) { yield a; } }"

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)

    assert Enum.any?(
             errors,
             &(&1.message == "duplicate parameter name not allowed in strict mode")
           )
  end
end
