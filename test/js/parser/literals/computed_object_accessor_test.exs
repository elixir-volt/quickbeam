defmodule QuickBEAM.JS.Parser.Literals.ComputedObjectAccessorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible computed object accessor syntax" do
    source = """
    value = {
      get [name]() { return 1; },
      set [name](value) { this.value = value; }
    };
    """

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{
                 properties: [
                   %AST.Property{key: %AST.Identifier{name: "name"}, kind: :get, computed: true},
                   %AST.Property{key: %AST.Identifier{name: "name"}, kind: :set, computed: true}
                 ]
               }
             }
           } = statement
  end
end
