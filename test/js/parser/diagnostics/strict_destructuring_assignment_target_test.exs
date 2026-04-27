defmodule QuickBEAM.JS.Parser.Diagnostics.StrictDestructuringAssignmentTargetTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict object destructuring eval assignment diagnostics" do
    source = ~S|"use strict"; ({ eval } = object);|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}, %AST.ExpressionStatement{}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted assignment target in strict mode"))
  end

  test "ports QuickJS strict array destructuring arguments assignment diagnostics" do
    source = ~S|"use strict"; [arguments] = array;|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}, %AST.ExpressionStatement{}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted assignment target in strict mode"))
  end
end
