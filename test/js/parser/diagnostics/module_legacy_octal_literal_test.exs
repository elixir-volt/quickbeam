defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleLegacyOctalLiteralTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module legacy octal literal diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.ExpressionStatement{}]},
            errors} =
             Parser.parse("value = 010;", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "legacy octal literal not allowed in strict mode"))
  end
end
