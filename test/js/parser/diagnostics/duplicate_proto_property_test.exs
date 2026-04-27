defmodule QuickBEAM.JS.Parser.Diagnostics.DuplicateProtoPropertyTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS duplicate __proto__ data property diagnostics" do
    source = "object = { __proto__: first, \"__proto__\": second };"

    assert {:error,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.AssignmentExpression{
                    right: %AST.ObjectExpression{properties: properties}
                  }
                }
              ]
            }, errors} =
             Parser.parse(source)

    assert length(properties) == 2
    assert Enum.any?(errors, &(&1.message == "duplicate __proto__ property"))
  end
end
