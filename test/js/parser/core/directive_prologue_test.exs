defmodule QuickBEAM.JS.Parser.Core.DirectivePrologueTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS strict directive prologue syntax" do
    source = """
    "use strict";
    function f() { "use strict"; return 1; }
    """

    assert {:ok, %AST.Program{body: [directive, function_decl]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{expression: %AST.Literal{value: "use strict"}} = directive

    assert %AST.FunctionDeclaration{
             body: %AST.BlockStatement{
               body: [
                 %AST.ExpressionStatement{expression: %AST.Literal{value: "use strict"}},
                 %AST.ReturnStatement{}
               ]
             }
           } = function_decl
  end
end
