defmodule QuickBEAM.JS.Parser.ControlFlow.AwaitUsingTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS await using declaration syntax" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{
                  body: %AST.BlockStatement{
                    body: [
                      %AST.VariableDeclaration{
                        kind: :await_using,
                        declarations: [
                          %AST.VariableDeclarator{id: %AST.Identifier{name: "resource"}}
                        ]
                      }
                    ]
                  }
                }
              ]
            }} = Parser.parse("async function f() { await using resource = value; }")
  end

  test "ports QuickJS await using declaration in for head" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{
                  body: %AST.BlockStatement{
                    body: [
                      %AST.ForStatement{
                        init: %AST.VariableDeclaration{kind: :await_using}
                      }
                    ]
                  }
                }
              ]
            }} =
             Parser.parse(
               "async function f() { for (await using resource = value; i < 1; i++) {} }"
             )
  end

  test "ports QuickJS await using declaration in for-of head" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{
                  body: %AST.BlockStatement{
                    body: [
                      %AST.ForOfStatement{
                        left: %AST.VariableDeclaration{kind: :await_using},
                        await: true
                      }
                    ]
                  }
                }
              ]
            }} = Parser.parse("async function f() { for (await using resource of values) {} }")
  end

  test "ports QuickJS await using element access expression syntax" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{
                  body: %AST.BlockStatement{
                    body: [
                      %AST.ExpressionStatement{
                        expression: %AST.AwaitExpression{
                          argument: %AST.MemberExpression{
                            object: %AST.Identifier{name: "using"},
                            computed: true
                          }
                        }
                      }
                    ]
                  }
                }
              ]
            }} = Parser.parse("async function f() { await using[x]; }")
  end

  test "ports QuickJS await using split across lines before let assignment" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{
                  body: %AST.BlockStatement{
                    body: [
                      %AST.ExpressionStatement{expression: %AST.AwaitExpression{}},
                      %AST.ExpressionStatement{
                        expression: %AST.AssignmentExpression{
                          left: %AST.Identifier{name: "let"}
                        }
                      }
                      | _
                    ]
                  }
                }
              ]
            }} = Parser.parse("async function f() { await using\nlet = value; var using, let; }")
  end
end
