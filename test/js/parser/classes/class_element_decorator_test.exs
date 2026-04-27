defmodule QuickBEAM.JS.Parser.Classes.ClassElementDecoratorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS class element call decorators" do
    source = """
    function decorator() { return () => {}; }
    var $ = decorator;
    class C {
      @$() method() {}
      @$() static method() {}
      @$() field;
      @$() static field;
    }
    """

    assert {:ok,
            %AST.Program{
              body: [
                %AST.FunctionDeclaration{},
                %AST.VariableDeclaration{},
                %AST.ClassDeclaration{
                  body: [
                    %AST.MethodDefinition{},
                    %AST.MethodDefinition{static: true},
                    %AST.FieldDefinition{},
                    %AST.FieldDefinition{static: true}
                  ]
                }
              ]
            }} = Parser.parse(source)
  end
end
