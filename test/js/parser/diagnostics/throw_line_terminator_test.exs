defmodule QuickBEAM.JS.Parser.Diagnostics.ThrowLineTerminatorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS throw line terminator diagnostics" do
    assert {:error,
            %AST.Program{body: [%AST.ThrowStatement{argument: nil}, %AST.ExpressionStatement{}]},
            errors} =
             Parser.parse("throw\nerror;")

    assert Enum.any?(errors, &(&1.message == "line terminator after throw"))
  end
end
