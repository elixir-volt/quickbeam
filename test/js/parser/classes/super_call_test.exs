defmodule QuickBEAM.JS.Parser.Classes.SuperCallTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS super constructor and super member call syntax" do
    source = """
    class D extends C {
      constructor() { super(); this.z = 20; }
      h() { return super.f(); }
      static H() { return super["F"](); }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{} = klass]}} = Parser.parse(source)

    assert %AST.ClassDeclaration{
             super_class: %AST.Identifier{name: "C"},
             body: [ctor, h, static_h]
           } = klass

    assert %AST.MethodDefinition{
             key: %AST.Identifier{name: "constructor"},
             value: %AST.FunctionExpression{body: ctor_body}
           } = ctor

    assert %AST.BlockStatement{
             body: [
               %AST.ExpressionStatement{
                 expression: %AST.CallExpression{callee: %AST.Identifier{name: "super"}}
               },
               _
             ]
           } = ctor_body

    assert %AST.MethodDefinition{key: %AST.Identifier{name: "h"}} = h
    assert %AST.MethodDefinition{key: %AST.Identifier{name: "H"}, static: true} = static_h
  end
end
