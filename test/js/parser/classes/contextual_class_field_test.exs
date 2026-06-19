defmodule QuickBEAM.JS.Parser.Classes.ContextualClassFieldTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS contextual get set async class field syntax" do
    source = """
    class P {
      get;
      set;
      async;
      get = () => "123";
      set = () => "456";
      async = () => "789";
      static() { return 42; }
    }
    """

    assert {:ok, %AST.Program{body: [%AST.ClassDeclaration{body: members}]}} =
             Parser.parse(source)

    assert [get_field, set_field, async_field, get_arrow, set_arrow, async_arrow, static_method] =
             members

    assert %AST.FieldDefinition{key: %AST.Identifier{name: "get"}, value: nil} = get_field
    assert %AST.FieldDefinition{key: %AST.Identifier{name: "set"}, value: nil} = set_field
    assert %AST.FieldDefinition{key: %AST.Identifier{name: "async"}, value: nil} = async_field

    assert %AST.FieldDefinition{
             key: %AST.Identifier{name: "get"},
             value: %AST.ArrowFunctionExpression{}
           } = get_arrow

    assert %AST.FieldDefinition{
             key: %AST.Identifier{name: "set"},
             value: %AST.ArrowFunctionExpression{}
           } = set_arrow

    assert %AST.FieldDefinition{
             key: %AST.Identifier{name: "async"},
             value: %AST.ArrowFunctionExpression{}
           } = async_arrow

    assert %AST.MethodDefinition{key: %AST.Identifier{name: "static"}, static: false} =
             static_method
  end
end
