defmodule QuickBEAM.JS.Parser.Functions.YieldSpreadObjectTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "parses yield expressions inside object spread without consuming sibling properties" do
    source =
      "async function *g() { yield { ...yield yield, ...(function(arg) { var yield = arg; return {...yield}; }(yield)), ...yield }; }"

    assert {:ok,
            %AST.Program{
              body: [%AST.FunctionDeclaration{body: %AST.BlockStatement{body: [statement]}}]
            }} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.YieldExpression{
               argument: %AST.ObjectExpression{properties: properties}
             }
           } = statement

    assert length(properties) == 3
  end
end
