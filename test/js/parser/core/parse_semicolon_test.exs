defmodule QuickBEAM.JS.Parser.Core.ParseSemicolonTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

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
