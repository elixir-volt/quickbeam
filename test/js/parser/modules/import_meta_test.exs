defmodule QuickBEAM.JS.Parser.Modules.ImportMetaTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible import.meta syntax" do
    assert {:ok, %AST.Program{body: [statement]}} =
             Parser.parse("url = import.meta.url;", source_type: :module)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.MemberExpression{
                 object: %AST.MetaProperty{
                   meta: %AST.Identifier{name: "import"},
                   property: %AST.Identifier{name: "meta"}
                 },
                 property: %AST.Identifier{name: "url"}
               }
             }
           } = statement
  end
end
