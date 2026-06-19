defmodule QuickBEAM.JS.Parser.ControlFlow.SloppyLetForHeadTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS sloppy let as for-in left-hand side" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{},
                %AST.ForInStatement{left: %AST.Identifier{name: "let"}}
              ]
            }} = Parser.parse("var let; for (let in {}) { }")
  end

  test "ports QuickJS sloppy let as classic for initializer expression" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{},
                %AST.ForStatement{init: %AST.Identifier{name: "let"}},
                %AST.ForStatement{
                  init: %AST.AssignmentExpression{left: %AST.Identifier{name: "let"}}
                }
              ]
            }} = Parser.parse("var let; for (let; ; ) break; for (let = 3; ; ) break;")
  end

  test "ports escaped let as identifier expression, not lexical declaration" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{expression: %AST.AssignmentExpression{}},
                %AST.ExpressionStatement{expression: %AST.Identifier{name: "let"}},
                %AST.ExpressionStatement{expression: %AST.Identifier{name: "a"}},
                %AST.VariableDeclaration{}
              ]
            }} = Parser.parse("this.let = 0;\nl\\u0065t\na;\nvar a;")
  end
end
