defmodule QuickBEAM.JS.Parser.Diagnostics.StrictWithStatementTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict program with-statement diagnostics" do
    source = ~S|"use strict"; with (object) { value; }|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}, %AST.WithStatement{}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "with statement not allowed in strict mode"))
  end

  test "ports QuickJS strict function with-statement diagnostics" do
    source = ~S|function f() { "use strict"; with (object) { value; } }|

    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{}]}, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "with statement not allowed in strict mode"))
  end
end
