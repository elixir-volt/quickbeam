defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleOctalEscapeTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module octal string escape diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.ExpressionStatement{}]},
            errors} =
             Parser.parse(~S|value = "\1";|, source_type: :module)

    assert Enum.any?(errors, &(&1.message == "octal escape sequence not allowed in strict mode"))
  end
end
