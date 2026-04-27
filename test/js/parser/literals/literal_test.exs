defmodule QuickBEAM.JS.Parser.Literals.LiteralTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS object literal contextual get/set/async parsing" do
    source = """
    var x = 0, get = 1, set = 2; async = 3;
    a = { get: 2, set: 3, async: 4, get a(){ return this.get} };
    a = { x, get, set, async };
    """

    assert {:ok, %AST.Program{body: [_vars, _assign_async, assign_object, assign_shorthand]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{properties: [get_prop, set_prop, async_prop, getter]}
             }
           } = assign_object

    assert %AST.Property{key: %AST.Identifier{name: "get"}, kind: :init} = get_prop
    assert %AST.Property{key: %AST.Identifier{name: "set"}, kind: :init} = set_prop
    assert %AST.Property{key: %AST.Identifier{name: "async"}, kind: :init} = async_prop
    assert %AST.Property{key: %AST.Identifier{name: "a"}, kind: :get} = getter

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{properties: shorthand}
             }
           } = assign_shorthand

    assert Enum.map(shorthand, & &1.shorthand) == [true, true, true, true]
  end

  test "ports QuickJS array spread literals" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("x = [1, 2, ...[3, 4]];")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ArrayExpression{elements: [_, _, %AST.SpreadElement{}]}
             }
           } = statement
  end
end
