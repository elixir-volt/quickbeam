defmodule QuickBEAM.JS.Parser.Diagnostics.StrictClassNameTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict class eval binding name diagnostics" do
    source = ~S|"use strict"; class eval {}|

    assert {:error,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{},
                %AST.ClassDeclaration{id: %AST.Identifier{name: "eval"}}
              ]
            }, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
