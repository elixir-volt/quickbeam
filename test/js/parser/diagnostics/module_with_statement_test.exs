defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleWithStatementTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module with-statement strict diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.WithStatement{}]}, errors} =
             Parser.parse("with (object) { value; }", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "with statement not allowed in strict mode"))
  end
end
