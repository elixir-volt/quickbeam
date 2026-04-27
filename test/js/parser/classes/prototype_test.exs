defmodule QuickBEAM.JS.Parser.Classes.PrototypeTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS prototype descriptor call syntax" do
    source = """
    var g = function g() { };
    Object.defineProperty(g, "prototype", { writable: false });
    assert(f.prototype.constructor, f, "prototype");
    """

    assert {:ok, %AST.Program{body: [_declaration, define_property, assertion]}} =
             Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{
               callee: %AST.MemberExpression{
                 object: %AST.Identifier{name: "Object"},
                 property: %AST.Identifier{name: "defineProperty"}
               },
               arguments: [
                 _,
                 _,
                 %AST.ObjectExpression{
                   properties: [%AST.Property{key: %AST.Identifier{name: "writable"}}]
                 }
               ]
             }
           } = define_property

    assert %AST.ExpressionStatement{
             expression: %AST.CallExpression{callee: %AST.Identifier{name: "assert"}}
           } = assertion
  end
end
