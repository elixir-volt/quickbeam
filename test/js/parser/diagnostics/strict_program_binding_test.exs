defmodule QuickBEAM.JS.Parser.Diagnostics.StrictProgramBindingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict top-level eval binding diagnostics" do
    source = ~S|"use strict"; var eval;|

    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}, %AST.VariableDeclaration{}]},
            errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end

  test "ports QuickJS strict top-level arguments function binding diagnostics" do
    source = ~S|"use strict"; function arguments() {}|

    assert {:error,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{},
                %AST.FunctionDeclaration{id: %AST.Identifier{name: "arguments"}}
              ]
            }, errors} =
             Parser.parse(source)

    assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
  end
end
