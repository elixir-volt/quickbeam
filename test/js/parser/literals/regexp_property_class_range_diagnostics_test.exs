defmodule QuickBEAM.JS.Parser.Literals.RegexpPropertyClassRangeDiagnosticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects unicode property escapes in class ranges" do
    for source <- [~S|/[\p{ASCII}-A]/u;|, ~S|/[A-\P{ASCII}]/u;|] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid class range"))
    end
  end
end
