defmodule QuickBEAM.JS.Parser.ControlFlow.ForAwaitDestructuringTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible for-await destructuring syntax" do
    source = """
    async function f(stream) {
      for await (const { value } of stream) { use(value); }
    }
    """

    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{
                  async: true,
                  body: %AST.BlockStatement{body: [statement]}
                }
              ]
            }} =
             Parser.parse(source)

    assert %AST.ForOfStatement{
             await: true,
             left: %AST.VariableDeclaration{
               kind: :const,
               declarations: [
                 %AST.VariableDeclarator{
                   id: %AST.ObjectPattern{
                     properties: [%AST.Property{key: %AST.Identifier{name: "value"}}]
                   }
                 }
               ]
             },
             right: %AST.Identifier{name: "stream"}
           } = statement
  end
end
