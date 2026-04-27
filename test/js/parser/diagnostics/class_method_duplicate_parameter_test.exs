defmodule QuickBEAM.JS.Parser.Diagnostics.ClassMethodDuplicateParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS class method duplicate parameter diagnostics" do
    source = "class C { method(a, a) { return a; } }"

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)

    assert Enum.any?(
             errors,
             &(&1.message == "duplicate parameter name not allowed in strict mode")
           )
  end
end
