defmodule QuickBEAM.JS.Parser.Diagnostics.NamespaceExportSourceErrorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS namespace export source diagnostics" do
    for source <- [~S(export * as ns;), ~S(export * as "external-name";)] do
      assert {:error, %AST.Program{source_type: :module}, errors} =
               Parser.parse(source, source_type: :module)

      assert Enum.any?(errors, &(&1.message == "expected from"))
    end
  end
end
