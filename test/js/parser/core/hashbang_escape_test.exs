defmodule QuickBEAM.JS.Parser.Core.HashbangEscapeTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS escaped hashbang diagnostics" do
    assert {:error, %AST.Program{}, errors} = Parser.parse(~S|\u0023\u0021|)
    assert Enum.any?(errors, &(&1.message == "invalid unicode escape in identifier"))
  end

  test "preserves escaped identifier syntax" do
    assert {:ok, %AST.Program{}} = Parser.parse(~S|var \u0061 = 1;|)
  end
end
