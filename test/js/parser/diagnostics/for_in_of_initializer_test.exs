defmodule QuickBEAM.JS.Parser.Diagnostics.ForInOfInitializerTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS for-of declaration initializer diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ForOfStatement{}]}, errors} =
             Parser.parse("for (let value = first of values) { break; }")

    assert Enum.any?(errors, &(&1.message == "for-in/of declaration cannot have initializer"))
  end
end
