defmodule QuickBEAM.JS.Parser.Diagnostics.InvalidStringEscapeTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS invalid string escape diagnostics" do
    for source <- [~s|"\\xZZ";|, ~s|"\\u00ZZ";|, ~s|"\\u{110000}";|] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid string escape"))
    end
  end
end
