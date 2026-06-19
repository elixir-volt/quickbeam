defmodule QuickBEAM.JS.Parser.Diagnostics.InvalidExponentTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS invalid numeric exponent diagnostics" do
    for source <- ["value = 1e;", "value = 1e+;", "value = 1e-;", "value = 1e_1;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid number literal"))
    end
  end
end
