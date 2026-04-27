defmodule QuickBEAM.JS.Parser.Literals.DivisionAfterBraceTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "parses division after object literals and function expressions" do
    source =
      "value = ({ valueOf: function() { return 1; } } / 1); other = (function(){} / function(){});"

    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{
                  expression: %AST.AssignmentExpression{
                    right: %AST.BinaryExpression{operator: "/"}
                  }
                },
                %AST.ExpressionStatement{
                  expression: %AST.AssignmentExpression{
                    right: %AST.BinaryExpression{operator: "/"}
                  }
                }
              ]
            }} = Parser.parse(source)
  end

  test "keeps regexp literals after block statements" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.IfStatement{},
                %AST.ExpressionStatement{
                  expression: %AST.CallExpression{
                    callee: %AST.MemberExpression{object: %AST.Literal{value: %{pattern: "abc"}}}
                  }
                }
              ]
            }} = Parser.parse("if (ok) {}\n/abc/.test(value);")
  end
end
