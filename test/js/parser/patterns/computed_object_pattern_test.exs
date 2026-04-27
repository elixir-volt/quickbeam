defmodule QuickBEAM.JS.Parser.Patterns.ComputedObjectPatternTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible computed object binding pattern syntax" do
    source = """
    var { [key]: value } = obj;
    function f({ [key]: value = 1 }) {}
    """

    assert {:ok, %AST.Program{body: [declaration, function_decl]}} = Parser.parse(source)

    assert %AST.VariableDeclaration{
             declarations: [
               %AST.VariableDeclarator{
                 id: %AST.ObjectPattern{
                   properties: [
                     %AST.Property{
                       computed: true,
                       key: %AST.Identifier{name: "key"},
                       value: %AST.Identifier{name: "value"}
                     }
                   ]
                 }
               }
             ]
           } = declaration

    assert %AST.FunctionDeclaration{
             params: [
               %AST.ObjectPattern{
                 properties: [
                   %AST.Property{
                     computed: true,
                     value: %AST.AssignmentPattern{left: %AST.Identifier{name: "value"}}
                   }
                 ]
               }
             ]
           } = function_decl
  end
end
