defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleAwaitArrowParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module await arrow parameter diagnostics" do
    assert {:error, %AST.Program{source_type: :module, body: [%AST.ExpressionStatement{}]},
            errors} =
             Parser.parse("fn = (await) => await;", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "expected binding identifier"))
  end
end
