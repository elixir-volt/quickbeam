defmodule QuickBEAM.JS.Parser.Diagnostics.StrictRestrictedAssignmentTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict eval assignment target diagnostics" do
    source = ~S|"use strict"; eval = value;|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}, %AST.ExpressionStatement{}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted assignment target in strict mode"))
  end

  test "ports QuickJS strict arguments compound assignment target diagnostics" do
    source = ~S|function f() { "use strict"; arguments += value; }|

    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{}]}, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted assignment target in strict mode"))
  end
end
