defmodule QuickBEAM.JS.Parser.Modules.DynamicImportStatementTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "parses dynamic import at statement position as a call expression" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.CallExpression{
                    callee: %AST.Identifier{name: "import"},
                    arguments: [%AST.Literal{value: "./module.js"}]
                  }
                }
              ]
            }} = Parser.parse(~s|import("./module.js");|)
  end

  test "parses dynamic import with options object" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.CallExpression{
                    callee: %AST.Identifier{name: "import"},
                    arguments: [
                      %AST.Literal{value: "./module.js"},
                      %AST.ObjectExpression{}
                    ]
                  }
                }
              ]
            }} = Parser.parse(~s|import("./module.js", { with: { type: "json" } });|)
  end
end
