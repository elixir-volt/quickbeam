defmodule QuickBEAM.JS.Parser.Diagnostics.BigIntSeparatorErrorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS bigint numeric separator diagnostics" do
    for source <- ["value = 1__0n;", "value = 0x_Fn;", "value = 0b_1n;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid numeric separator"))
    end
  end
end
