defmodule QuickBEAM.JS.Parser.Diagnostics.StrictDestructuringBindingNameTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict object destructuring eval binding diagnostics" do
    source = ~S|"use strict"; var { eval } = object;|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}, %AST.VariableDeclaration{}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end

  test "ports QuickJS strict array destructuring arguments binding diagnostics" do
    source = ~S|"use strict"; var [arguments] = array;|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}, %AST.VariableDeclaration{}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
