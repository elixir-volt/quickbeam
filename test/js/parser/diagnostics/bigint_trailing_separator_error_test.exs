defmodule QuickBEAM.JS.Parser.Diagnostics.BigIntTrailingSeparatorErrorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS bigint trailing separator diagnostics" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("value = 1_n;")
    assert Enum.any?(errors, &(&1.message == "invalid numeric separator"))
  end
end
