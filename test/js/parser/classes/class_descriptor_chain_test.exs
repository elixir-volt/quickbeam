defmodule QuickBEAM.JS.Parser.Classes.ClassDescriptorChainTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS class descriptor member chain syntax" do
    source = ~s|Object.getOwnPropertyDescriptor(C.prototype, "y").get.name === "get y";|

    assert {:ok, %AST.Program{body: [statement]}} = Parser.parse(source)

    assert %AST.ExpressionStatement{
             expression: %AST.BinaryExpression{
               operator: "===",
               left: %AST.MemberExpression{
                 property: %AST.Identifier{name: "name"},
                 object: %AST.MemberExpression{
                   property: %AST.Identifier{name: "get"},
                   object: %AST.CallExpression{
                     callee: %AST.MemberExpression{
                       property: %AST.Identifier{name: "getOwnPropertyDescriptor"}
                     },
                     arguments: [
                       %AST.MemberExpression{property: %AST.Identifier{name: "prototype"}},
                       %AST.Literal{value: "y"}
                     ]
                   }
                 }
               },
               right: %AST.Literal{value: "get y"}
             }
           } = statement
  end
end
