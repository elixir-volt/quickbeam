defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleDestructuringAssignmentTargetTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module destructuring eval assignment diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.ExpressionStatement{}]},
            errors} =
             Parser.parse("({ eval } = object);", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "restricted assignment target in strict mode"))
  end
end
