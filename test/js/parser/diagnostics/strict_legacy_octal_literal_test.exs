defmodule QuickBEAM.JS.Parser.Diagnostics.StrictLegacyOctalLiteralTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict legacy octal literal diagnostics" do
    source = ~S|"use strict"; value = 010;|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}, %AST.ExpressionStatement{}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "legacy octal literal not allowed in strict mode"))
  end

  test "ports QuickJS sloppy legacy octal literal allowance" do
    assert {:ok, %AST.Program{body: [%AST.ExpressionStatement{}]}} = Parser.parse("value = 010;")
  end
end
