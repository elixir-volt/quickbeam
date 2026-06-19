defmodule QuickBEAM.JS.Parser.Classes.PrivateFieldTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS new expression call chain coverage" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("assert(new Q().f(), 5);")

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.Identifier{name: "assert"},
               arguments: [
                 %AST.CallExpression{callee: %AST.MemberExpression{object: %AST.NewExpression{}}},
                 _
               ]
             }
           } = statement
  end

  test "ports QuickJS private field division parse coverage" do
    source = """
    class Q {
      #x = 10;
      f() { return (this.#x / 2); }
    }
    assert(new Q().f(), 5);
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{} = klass, assertion]}} =
             Parser.parse(source)

    assert %AST.ClassDeclaration{
             id: %AST.Identifier{name: "Q"},
             body: [
               %AST.FieldDefinition{key: %AST.PrivateIdentifier{name: "x"}},
               %AST.MethodDefinition{
                 key: %AST.Identifier{name: "f"},
                 value: %AST.FunctionExpression{body: body}
               }
             ]
           } = klass

    assert %AST.BlockStatement{
             body: [%AST.ReturnStatement{argument: %AST.BinaryExpression{operator: "/"}}]
           } = body

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.Identifier{name: "assert"},
               arguments: [
                 %AST.CallExpression{callee: %AST.MemberExpression{object: %AST.NewExpression{}}},
                 _
               ]
             }
           } = assertion
  end
end
