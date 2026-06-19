defmodule QuickBEAM.JS.Parser.Diagnostics.ImportSourceErrorTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS import source diagnostics" do
    for source <- [
          ~S(import value from dep;),
          ~S(import { value } from dep;),
          ~S(import * as ns from dep;)
        ] do
      assert {:error, %AST.Program{source_type: :module}, errors} =
               Parser.parse(source, source_type: :module)

      assert Enum.any?(errors, &(&1.message == "expected module source"))
    end
  end
end
