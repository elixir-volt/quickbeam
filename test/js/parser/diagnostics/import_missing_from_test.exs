defmodule QuickBEAM.JS.Parser.Diagnostics.ImportMissingFromTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS import missing from diagnostics" do
    for source <- [
          ~S(import value "dep";),
          ~S(import { value } "dep";),
          ~S(import * as ns "dep";)
        ] do
      assert {:error, %AST.Program{source_type: :module}, errors} =
               Parser.parse(source, source_type: :module)

      assert Enum.any?(errors, &(&1.message == "expected from"))
    end
  end
end
