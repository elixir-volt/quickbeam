defmodule QuickBEAM.JS.Parser.Literals.TemplateExpressionEscapeTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "does not validate string escapes inside template expressions as template escapes" do
    assert {:ok, %AST.Program{}} = Parser.parse(~S|`${'\07'}`;|)
  end

  test "rejects string octal escapes inside template expressions in strict mode" do
    assert {:error, %AST.Program{}, errors} = Parser.parse(~S|"use strict"; `${'\07'}`;|)
    assert Enum.any?(errors, &(&1.message == "octal escape sequence not allowed in strict mode"))
  end

  test "continues rejecting legacy octal escapes in untagged template quasis" do
    assert {:error, %AST.Program{}, errors} = Parser.parse(~S|`\07`;|)
    assert Enum.any?(errors, &(&1.message == "invalid template escape sequence"))
  end
end
