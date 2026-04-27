defmodule QuickBEAM.JS.Parser.Diagnostics.IfSyntaxErrorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS if statement missing-parentheses syntax errors" do
    for source <- ["if 'abc'", "if `abc`", "if /abc/", "if abcd", "if abc\\u0064", "if \\u0123"] do
      assert {:error, %AST.Program{}, [_ | _]} = Parser.parse(source)
    end
  end
end
