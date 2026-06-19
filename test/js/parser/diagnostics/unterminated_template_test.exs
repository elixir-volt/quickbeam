defmodule QuickBEAM.JS.Parser.Diagnostics.UnterminatedTemplateTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS unterminated template diagnostics" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("value = `unterminated")
    assert Enum.any?(errors, &(&1.message == "unterminated template literal"))
  end
end
