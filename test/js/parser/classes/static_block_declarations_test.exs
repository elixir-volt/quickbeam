defmodule QuickBEAM.JS.Parser.Classes.StaticBlockDeclarationsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible static block declaration syntax" do
    source = """
    class C {
      static {
        const value = 1;
        function helper() { return value; }
        this.value = helper();
      }
    }
    """

    assert {:ok,
            %AST.Program{body: [%AST.ClassDeclaration{body: [%AST.StaticBlock{body: body}]}]}} =
             Parser.parse(source)

    assert [
             %AST.VariableDeclaration{kind: :const},
             %AST.FunctionDeclaration{id: %AST.Identifier{name: "helper"}},
             %AST.ExpressionStatement{expression: %AST.AssignmentExpression{}}
           ] = body
  end
end
