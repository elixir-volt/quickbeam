defmodule QuickBEAM.JS.Parser.Literals.RegexpFlagDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects invalid and duplicate regexp flags" do
    for source <- ["/./G;", "/./gig;", "/./uv;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid regular expression flags"))
    end
  end

  test "allows supported regexp flags" do
    assert {:ok, %AST.Program{}} = Parser.parse("/./dgimsuy;")
  end
end
