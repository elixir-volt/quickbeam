defmodule QuickBEAM.JS.Parser.Literals.UnicodeWhitespaceIdentifierBoundaryTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "treats NBSP as whitespace between tokens but not inside escaped identifiers" do
    assert {:ok, %AST.Program{}} = Parser.parse("\u00A0var x\u00A0= 2\u00A0;")
    assert {:error, %AST.Program{}, [_ | _]} = Parser.parse("var\\u00A0x;")
  end

  test "rejects Mongolian vowel separator between identifier parts" do
    assert {:error, %AST.Program{}, [_ | _]} = Parser.parse("var\u180Efoo;")
  end
end
