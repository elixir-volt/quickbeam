defmodule QuickBEAM.JS.Parser.Diagnostics.ImportMetaContextTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS script import.meta context diagnostics" do
    assert {:error, %AST.Program{body: [%AST.VariableDeclaration{}]}, errors} =
             Parser.parse("let url = import.meta.url;")

    assert Enum.any?(errors, &(&1.message == "import.meta only allowed in modules"))
  end

  test "ports QuickJS function import.meta context diagnostics in scripts" do
    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{}]}, errors} =
             Parser.parse("function f() { return import.meta.url; }")

    assert Enum.any?(errors, &(&1.message == "import.meta only allowed in modules"))
  end
end
