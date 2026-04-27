defmodule QuickBEAM.JS.Parser.Diagnostics.StrictClassBodyBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS class method strict body binding diagnostics" do
    source = ~S|class C { method() { var eval; } }|

    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end

  test "ports QuickJS class static block strict binding diagnostics" do
    source = ~S|class C { static { var arguments; } }|

    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
