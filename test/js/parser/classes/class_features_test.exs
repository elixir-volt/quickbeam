defmodule QuickBEAM.JS.Parser.Classes.ClassFeaturesTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS class extends static method getter and field syntax" do
    source = """
    class C { static F() { return -1; } get y() { return 12; } }
    class D extends C { static G() { return -2; } h() { return super.f(); } static H() { return super["F"](); } }
    class S { static x = 42; static y = S.x; }
    """

    assert {:ok, %AST.Program{body: [c, d, s]}} = Parser.parse(source)

    assert %AST.ClassDeclaration{
             id: %AST.Identifier{name: "C"},
             body: [
               %AST.MethodDefinition{key: %AST.Identifier{name: "F"}, static: true},
               %AST.MethodDefinition{key: %AST.Identifier{name: "y"}, kind: :get}
             ]
           } = c

    assert %AST.ClassDeclaration{super_class: %AST.Identifier{name: "C"}, body: d_body} = d

    assert Enum.any?(
             d_body,
             &match?(%AST.MethodDefinition{key: %AST.Identifier{name: "H"}, static: true}, &1)
           )

    assert %AST.ClassDeclaration{
             body: [
               %AST.FieldDefinition{key: %AST.Identifier{name: "x"}, static: true},
               %AST.FieldDefinition{key: %AST.Identifier{name: "y"}, static: true}
             ]
           } = s
  end

  test "ports QuickJS class expression name scope syntax" do
    assert {:ok, %AST.Program{body: [declaration]}} =
             Parser.parse("var E1 = class E { static F() { return E; } };")

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{init: %AST.ClassExpression{id: %AST.Identifier{name: "E"}}}
             ]
           } = declaration
  end
end
