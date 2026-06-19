defmodule QuickBEAM.JS.Parser.Diagnostics.TryMissingHandlerTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS try without catch or finally diagnostics" do
    assert {:error, %AST.Program{body: [%AST.TryStatement{handler: nil, finalizer: nil}]}, errors} =
             Parser.parse("try { work(); }")

    assert Enum.any?(errors, &(&1.message == "expected catch or finally"))
  end
end
