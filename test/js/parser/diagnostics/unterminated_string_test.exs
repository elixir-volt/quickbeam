defmodule QuickBEAM.JS.Parser.Diagnostics.UnterminatedStringTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS unterminated string diagnostics" do
    for source <- [~S(value = "unterminated), "value = \"line\nbreak\";"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "unterminated string literal"))
    end
  end
end
