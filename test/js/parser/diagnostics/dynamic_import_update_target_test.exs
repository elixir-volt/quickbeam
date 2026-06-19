defmodule QuickBEAM.JS.Parser.Diagnostics.DynamicImportUpdateTargetTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects dynamic import calls as update targets" do
    for source <- ["++import('mod')", "--import('mod')", "import('mod')++"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid assignment target"))
    end
  end
end
