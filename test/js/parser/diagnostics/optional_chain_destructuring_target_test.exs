defmodule QuickBEAM.JS.Parser.Diagnostics.OptionalChainDestructuringTargetTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS optional chain object assignment pattern diagnostics" do
    source = "({ target: object?.property } = source);"

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "optional chain is not a valid assignment target"))
  end

  test "ports QuickJS optional chain array assignment pattern diagnostics" do
    source = "[object?.property] = source;"

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "optional chain is not a valid assignment target"))
  end
end
