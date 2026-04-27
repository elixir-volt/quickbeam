defmodule QuickBEAM.JS.Parser.Diagnostics.ClassLegacyOctalLiteralTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS class method legacy octal literal diagnostics" do
    source = "class C { method() { return 010; } }"

    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "legacy octal literal not allowed in strict mode"))
  end
end
