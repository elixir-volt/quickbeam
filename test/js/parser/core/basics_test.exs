defmodule QuickBEAM.JS.Parser.Core.BasicsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST
  alias QuickBEAM.JS.Parser.Lexer

  test "lexer tracks line terminators before tokens" do
    assert {:ok, tokens} = Lexer.tokenize("let x = 1\nreturn x")
    return = Enum.find(tokens, &(&1.value == "return"))
    x = tokens |> Enum.reverse() |> Enum.find(&(&1.value == "x"))

    assert return.before_line_terminator?
    refute x.before_line_terminator?
  end

  test "parses variable declarations with Pratt expression precedence" do
    assert {:ok, %AST.Program{body: [declaration]}} = Parser.parse("let x = 1 + 2 * 3;")
    assert %AST.VariableDeclaration{kind: :let, declarations: [declarator]} = declaration
    assert %AST.Identifier{name: "x"} = declarator.id

    assert %AST.BinaryExpression{operator: "+", right: %AST.BinaryExpression{operator: "*"}} =
             declarator.init
  end

  test "parses calls and member expressions" do
    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse("foo(1, bar).baz")

    assert %AST.ExpressionStatement{
             expression: %AST.MemberExpression{
               property: %AST.Identifier{name: "baz"},
               object: %AST.CallExpression{callee: %AST.Identifier{name: "foo"}, arguments: args}
             }
           } = statement

    assert [%AST.Literal{value: 1}, %AST.Identifier{name: "bar"}] = args
  end

  test "return statement observes automatic semicolon insertion line terminator" do
    assert {:error, %AST.Program{body: [return, expression]}, errors} =
             Parser.parse("return\nvalue")

    assert %AST.ReturnStatement{argument: nil} = return
    assert %AST.ExpressionStatement{expression: %AST.Identifier{name: "value"}} = expression
    assert Enum.any?(errors, &(&1.message == "return statement not within function"))
  end

  test "reports syntax errors while returning a partial AST" do
    assert {:error, %AST.Program{}, [error | _]} = Parser.parse("const;")
    assert error.message == "expected binding identifier"
  end
end
