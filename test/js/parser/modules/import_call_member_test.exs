defmodule QuickBEAM.JS.Parser.Modules.ImportCallMemberTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "parses import.defer as a member call expression" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.CallExpression{
                    callee: %AST.MemberExpression{
                      object: %AST.Identifier{name: "import"},
                      property: %AST.Identifier{name: "defer"}
                    },
                    arguments: [%AST.Identifier{name: "specifier"}]
                  }
                }
              ]
            }} = Parser.parse("import.defer(specifier);")
  end

  test "keeps import.meta as a meta property" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.MemberExpression{
                    object: %AST.MetaProperty{},
                    property: %AST.Identifier{name: "url"}
                  }
                }
              ]
            }} = Parser.parse("import.meta.url;", source_type: :module)
  end
end
