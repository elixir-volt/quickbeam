defmodule QuickBEAM.JS.ParserTest do
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
    assert {:ok, %AST.Program{body: [return, expression]}} = Parser.parse("return\nvalue")
    assert %AST.ReturnStatement{argument: nil} = return
    assert %AST.ExpressionStatement{expression: %AST.Identifier{name: "value"}} = expression
  end

  test "reports syntax errors while returning a partial AST" do
    assert {:error, %AST.Program{}, [error | _]} = Parser.parse("let = 1")
    assert error.message == "expected binding identifier"
  end
end

defmodule QuickBEAM.JS.QuickJSPortParserTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS parse semicolon yield/await regression" do
    source = """
    function test_parse_semicolon()
    {
        function *f()
        {
            function func() {
            }
            yield 1;
            var h = x => x + 1
            yield 2;
        }
        async function g()
        {
            function func() {
            }
            await 1;
            var h = x => x + 1
            await 2;
        }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.FunctionDeclaration{} = outer]}} = Parser.parse(source)
    assert outer.id.name == "test_parse_semicolon"

    assert [
             %AST.FunctionDeclaration{id: %AST.Identifier{name: "f"}, generator: true},
             %AST.FunctionDeclaration{id: %AST.Identifier{name: "g"}, async: true}
           ] = outer.body.body
  end
end

defmodule QuickBEAM.JS.LiteralParserTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "parses object and array literals" do
    assert {:ok, %AST.Program{body: [statement]}} =
             Parser.parse("value = { a: [1, 2], b, c() { return 3; } };")

    assert %AST.ExpressionStatement{
             expression: %AST.AssignmentExpression{
               right: %AST.ObjectExpression{properties: [a, b, c]}
             }
           } = statement

    assert %AST.Property{key: %AST.Identifier{name: "a"}, value: %AST.ArrayExpression{elements: [_, _]}} = a
    assert %AST.Property{key: %AST.Identifier{name: "b"}, shorthand: true} = b
    assert %AST.Property{key: %AST.Identifier{name: "c"}, method: true, value: %AST.FunctionExpression{}} = c
  end
end
