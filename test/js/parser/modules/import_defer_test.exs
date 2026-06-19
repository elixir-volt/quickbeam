defmodule QuickBEAM.JS.Parser.Modules.ImportDeferTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "parses static deferred namespace imports" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ImportDeclaration{
                  specifiers: [
                    %AST.ImportNamespaceSpecifier{local: %AST.Identifier{name: "ns"}}
                  ],
                  source: %AST.Literal{value: "./dep.js"}
                }
              ]
            }} = Parser.parse(~s|import defer * as ns from "./dep.js";|, source_type: :module)
  end
end
