defmodule QuickBEAM.JS.Parser.Literals.BracedSurrogateEscapeTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports SpiderMonkey braced unicode string escapes for surrogate code points" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{expression: %AST.Literal{value: <<0xD83E::16>>}},
                %AST.ExpressionStatement{expression: %AST.Literal{value: <<0xDD21::16>>}}
              ]
            }} = Parser.parse(~S|"\u{d83e}"; "\u{dd21}";|)
  end
end
