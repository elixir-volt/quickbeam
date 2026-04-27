defmodule QuickBEAM.JS.Parser.Modules.ImportSourceTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS source phase import binding syntax" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ImportDeclaration{
                  specifiers: [
                    %AST.ImportDefaultSpecifier{local: %AST.Identifier{name: "source"}}
                  ],
                  source: %AST.Literal{value: "module"}
                },
                %AST.ImportDeclaration{
                  specifiers: [%AST.ImportDefaultSpecifier{local: %AST.Identifier{name: "from"}}],
                  source: %AST.Literal{value: "module"}
                }
              ]
            }} =
             Parser.parse(
               "import source source from 'module';\nimport source from from 'module';",
               source_type: :module
             )
  end

  test "keeps source as an ordinary default import name" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ImportDeclaration{
                  specifiers: [
                    %AST.ImportDefaultSpecifier{local: %AST.Identifier{name: "source"}}
                  ],
                  source: %AST.Literal{value: "module"}
                }
              ]
            }} = Parser.parse("import source from 'module';", source_type: :module)
  end
end
