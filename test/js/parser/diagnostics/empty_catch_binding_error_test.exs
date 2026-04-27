defmodule QuickBEAM.JS.Parser.Diagnostics.EmptyCatchBindingErrorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS empty catch binding diagnostics" do
    assert {:error, %AST.Program{body: [%AST.TryStatement{handler: %AST.CatchClause{}}]}, errors} =
             Parser.parse("try { work(); } catch () { recover(); }")

    assert Enum.any?(errors, &(&1.message == "expected binding identifier"))
  end
end
