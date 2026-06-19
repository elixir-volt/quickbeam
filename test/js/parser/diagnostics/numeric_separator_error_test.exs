defmodule QuickBEAM.JS.Parser.Diagnostics.NumericSeparatorErrorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS numeric separator diagnostics" do
    for source <- ["value = 1__0;", "value = 1_;", "value = 0x_F;", "value = 0b_1;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid numeric separator"))
    end
  end
end
