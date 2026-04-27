defmodule QuickBEAM.JS.Parser.Diagnostics.InvalidUnicodeEscapeTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS invalid unicode escape identifier diagnostics" do
    for source <- ["var bad\\u{110000} = 1;", "var bad\\u{D800} = 1;", "var bad\\u00ZZ = 1;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid unicode escape in identifier"))
    end
  end
end
