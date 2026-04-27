defmodule QuickBEAM.JS.Parser.Diagnostics.ObjectRestNotLastTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS object rest binding must be last diagnostics" do
    source = "var { ...rest, after } = object;"

    assert {:error,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{declarations: [%AST.VariableDeclarator{id: pattern}]}
              ]
            }, errors} =
             Parser.parse(source)

    assert %AST.ObjectPattern{
             properties: [
               %AST.RestElement{argument: %AST.Identifier{name: "rest"}},
               %AST.Property{key: %AST.Identifier{name: "after"}}
             ]
           } = pattern

    assert Enum.any?(errors, &(&1.message == "rest element must be last"))
  end
end
