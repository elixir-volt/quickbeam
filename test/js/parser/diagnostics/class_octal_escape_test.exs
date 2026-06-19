defmodule QuickBEAM.JS.Parser.Diagnostics.ClassOctalEscapeTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS class method octal string escape diagnostics" do
    source = ~S|class C { method() { return "\1"; } }|

    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "octal escape sequence not allowed in strict mode"))
  end
end
