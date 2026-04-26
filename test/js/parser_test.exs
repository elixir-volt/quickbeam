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

    assert %AST.Property{
             key: %AST.Identifier{name: "a"},
             value: %AST.ArrayExpression{elements: [_, _]}
           } = a

    assert %AST.Property{key: %AST.Identifier{name: "b"}, shorthand: true} = b

    assert %AST.Property{
             key: %AST.Identifier{name: "c"},
             method: true,
             value: %AST.FunctionExpression{}
           } = c
  end
end

defmodule QuickBEAM.JS.QuickJSLiteralPortParserTest do
  use ExUnit.Case, async: true

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

defmodule QuickBEAM.JS.QuickJSControlFlowPortParserTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS labeled statement parse coverage" do
    source = """
    do x: { break x; } while(0);
    if (1)
        x: { break x; }
    else
        x: { break x; }
    with ({}) x: { break x; };
    while (0) x: { break x; };
    """

    assert {:ok,
            %AST.Program{body: [do_while, if_stmt, with_stmt, while_stmt, %AST.EmptyStatement{}]}} =
             Parser.parse(source)

    assert %AST.DoWhileStatement{body: %AST.LabeledStatement{label: %AST.Identifier{name: "x"}}} =
             do_while

    assert %AST.IfStatement{
             consequent: %AST.LabeledStatement{},
             alternate: %AST.LabeledStatement{}
           } = if_stmt

    assert %AST.WithStatement{body: %AST.LabeledStatement{}} = with_stmt
    assert %AST.WhileStatement{body: %AST.LabeledStatement{}} = while_stmt
  end
end
