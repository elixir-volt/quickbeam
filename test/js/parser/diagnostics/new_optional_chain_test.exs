defmodule QuickBEAM.JS.Parser.Diagnostics.NewOptionalChainTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS new optional member chain diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("value = new object?.Ctor();")

    assert Enum.any?(errors, &(&1.message == "optional chain not allowed after new"))
  end

  test "ports QuickJS new optional computed chain diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("value = new object?.[Ctor]();")

    assert Enum.any?(errors, &(&1.message == "optional chain not allowed after new"))
  end
end
