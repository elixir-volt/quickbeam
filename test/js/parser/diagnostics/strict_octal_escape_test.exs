defmodule QuickBEAM.JS.Parser.Diagnostics.StrictOctalEscapeTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict octal string escape diagnostics" do
    source = ~S|"use strict"; value = "\1";|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}, %AST.ExpressionStatement{}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "octal escape sequence not allowed in strict mode"))
  end

  test "ports QuickJS sloppy octal string escape allowance" do
    assert {:ok, %AST.Program{body: [%AST.ExpressionStatement{}]}} =
             Parser.parse(~S|value = "\1";|)
  end
end
