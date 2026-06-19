defmodule QuickBEAM.JS.Parser.Core.HTMLCommentsTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS-compatible HTML open comments" do
    source = """
    value = 1;
    <!-- comment text
    value = 2;<!-- trailing comment text
    value = -1 <!-- comment text
    """

    assert {:ok, %AST.Program{body: statements}} = Parser.parse(source)
    assert length(statements) == 3
  end

  test "ports QuickJS-compatible HTML close comments at line start" do
    source = """
       --> first-line comment after whitespace
    /* block comment */ --> first-line comment after block comment
    value = 1;
    --> comment text
       --> comment text after whitespace
    /**/ --> comment text after block comment
    value = 2;
    """

    assert {:ok, %AST.Program{body: statements}} = Parser.parse(source)
    assert length(statements) == 2
  end
end
