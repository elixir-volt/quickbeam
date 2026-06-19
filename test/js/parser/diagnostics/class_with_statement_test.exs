defmodule QuickBEAM.JS.Parser.Diagnostics.ClassWithStatementTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS class method with-statement strict diagnostics" do
    source = "class C { method() { with (object) { value; } } }"

    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "with statement not allowed in strict mode"))
  end
end
