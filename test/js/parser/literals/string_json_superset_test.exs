defmodule QuickBEAM.JS.Parser.Literals.StringJSONSupersetTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS U+2028 and U+2029 inside string literals" do
    line_separator = <<0x2028::utf8>>
    paragraph_separator = <<0x2029::utf8>>

    source =
      IO.iodata_to_binary([?", line_separator, ?", ?;, ?\n, ?", paragraph_separator, ?", ?;])

    assert {:ok,
            %AST.Program{
              body: [
                %AST.ExpressionStatement{expression: %AST.Literal{value: ^line_separator}},
                %AST.ExpressionStatement{expression: %AST.Literal{value: ^paragraph_separator}}
              ]
            }} = Parser.parse(source)
  end
end
