defmodule QuickBEAM.JS.Parser.Functions.GeneratorConstructorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS generator constructor try-catch syntax" do
    source = """
    function *G() {}
    let ex;
    try { new G(); } catch (ex_) { ex = ex_; }
    """

    assert {:ok, %AST.Program{body: [generator, declaration, try_statement]}} =
             Parser.parse(source)

    assert %AST.FunctionDeclaration{id: %AST.Identifier{name: "G"}, generator: true} = generator

    assert %AST.VariableDeclaration{
             kind: :let,
             declarations: [%AST.VariableDeclarator{id: %AST.Identifier{name: "ex"}}]
           } = declaration

    assert %AST.TryStatement{
             block: %AST.BlockStatement{
               body: [
                 %AST.ExpressionStatement{
                   expression: %AST.NewExpression{callee: %AST.Identifier{name: "G"}}
                 }
               ]
             },
             handler: %{param: %AST.Identifier{name: "ex_"}, body: %AST.BlockStatement{}}
           } = try_statement
  end
end
