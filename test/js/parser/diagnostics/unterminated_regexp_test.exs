defmodule QuickBEAM.JS.Parser.Diagnostics.UnterminatedRegexpTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS unterminated regexp diagnostics" do
    for source <- ["value = /unterminated", "value = /line\nbreak/;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "unterminated regular expression literal"))
    end
  end
end
