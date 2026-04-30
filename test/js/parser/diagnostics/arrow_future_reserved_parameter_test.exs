defmodule QuickBEAM.JS.Parser.Diagnostics.ArrowFutureReservedParameterTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects enum as an arrow binding identifier" do
    assert {:error, %AST.Program{}, errors} = Parser.parse("var af = enum => 1;")
    assert Enum.any?(errors, &(&1.message == "expected binding identifier"))
  end
end
