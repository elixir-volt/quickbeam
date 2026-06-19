defmodule QuickBEAM.JS.Parser.Diagnostics.TopLevelReturnTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS top-level return diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ReturnStatement{}]}, errors} =
             Parser.parse("return value;")

    assert Enum.any?(errors, &(&1.message == "return statement not within function"))
  end

  test "ports QuickJS return diagnostics from top-level block" do
    assert {:error, %AST.Program{body: [%AST.BlockStatement{}]}, errors} =
             Parser.parse("{ return; }")

    assert Enum.any?(errors, &(&1.message == "return statement not within function"))
  end
end
