defmodule QuickBEAM.JS.Parser.Diagnostics.ArrayRestNotLastTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS array rest binding must be last diagnostics" do
    source = "var [first, ...rest, after] = value;"

    assert {:error,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{declarations: [%AST.VariableDeclarator{id: pattern}]}
              ]
            }, errors} =
             Parser.parse(source)

    assert %AST.ArrayPattern{
             elements: [
               %AST.Identifier{name: "first"},
               %AST.RestElement{argument: %AST.Identifier{name: "rest"}},
               %AST.Identifier{name: "after"}
             ]
           } = pattern

    assert Enum.any?(errors, &(&1.message == "rest element must be last"))
  end
end
