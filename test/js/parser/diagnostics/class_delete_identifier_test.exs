defmodule QuickBEAM.JS.Parser.Diagnostics.ClassDeleteIdentifierTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS class method delete identifier strict diagnostics" do
    source = "class C { method() { delete value; } }"

    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "delete of identifier not allowed in strict mode"))
  end
end
