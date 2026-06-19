defmodule QuickBEAM.JS.Parser.Diagnostics.ModuleAwaitCatchParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module await catch parameter diagnostics" do
    source = "try { work(); } catch (await) { recover(); }"

    assert {:error, %AST.Program{source_type: :module, body: [%AST.TryStatement{}]}, errors} =
             Parser.parse(source, source_type: :module)

    assert Enum.any?(errors, &(&1.message == "expected binding identifier"))
  end
end
