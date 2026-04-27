defmodule QuickBEAM.JS.Parser.Classes.DecoratorSyntaxTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  @moduletag :quickjs_port

  test "parses decorated class expressions with member and call decorators" do
    source = "var C = @$() @ns.await @(yield) class {};"

    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{
                  declarations: [
                    %AST.VariableDeclarator{init: %AST.ClassExpression{}}
                  ]
                }
              ]
            }} = Parser.parse(source)
  end

  test "parses decorated class expressions with private member decorators" do
    source = "class C { static #x() {} static { var D = @C.#x class {}; } }"

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{}]}} = Parser.parse(source)
  end
end
