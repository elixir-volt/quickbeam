defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleDeleteIdentifierTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module delete identifier strict diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.ExpressionStatement{}]},
            errors} =
             Parser.parse("delete value;", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "delete of identifier not allowed in strict mode"))
  end
end
